#!/usr/bin/env bash
# Lab 13 — 백업 전략 수립 및 캡스톤 전체 통합 검증
#
# 마지막 랩이다. AWS Backup 으로 보호 체계를 세우고,
# Lab 1~12 에서 쌓아 올린 아키텍처가 전 구간 살아 있는지 확인한다.
source "$(dirname "$0")/../00-common/bootstrap.sh"
guard
banner "Lab 13 build — 백업 전략 및 통합 검증"
LAB=13

# ---------- 1. 백업 볼트 ----------
if aws backup describe-backup-vault --backup-vault-name "$N_BACKUP_VAULT" >/dev/null 2>&1; then
  skip "백업 볼트 $N_BACKUP_VAULT"
else
  aws backup create-backup-vault --backup-vault-name "$N_BACKUP_VAULT" \
    --backup-vault-tags Project=capstone,Lab=$LAB,Owner="$PREFIX" >/dev/null
  ok "백업 볼트 생성: $N_BACKUP_VAULT"
fi

# ---------- 2. 서비스 역할 ----------
B_TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"backup.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
if aws iam get-role --role-name "$N_ROLE_BACKUP" >/dev/null 2>&1; then
  skip "역할 $N_ROLE_BACKUP"
else
  aws iam create-role --role-name "$N_ROLE_BACKUP" --assume-role-policy-document "$B_TRUST" \
    --tags Key=Project,Value=capstone Key=Owner,Value="$PREFIX" >/dev/null
  ok "Backup 서비스 역할 생성"
fi
for P in AWSBackupServiceRolePolicyForBackup AWSBackupServiceRolePolicyForRestores; do
  aws iam attach-role-policy --role-name "$N_ROLE_BACKUP" \
    --policy-arn "arn:aws:iam::aws:policy/service-role/$P" >/dev/null 2>&1 || true
done
B_ROLE_ARN="$(_q aws iam get-role --role-name "$N_ROLE_BACKUP" --query Role.Arn --output text)"
save_state BACKUP_ROLE_ARN "$B_ROLE_ARN"

# ---------- 3. 백업 계획 ----------
# Free Tier 는 보존 기간 제약이 있을 수 있어 실패 시 완화한다.
PLAN_ID="$(_q aws backup list-backup-plans \
  --query "BackupPlansList[?BackupPlanName=='$N_BACKUP_PLAN'].BackupPlanId | [0]" --output text)"
if [ -z "$PLAN_ID" ]; then
  DAILY="${BACKUP_DAILY_DAYS:-35}"; WEEKLY="${BACKUP_WEEKLY_DAYS:-90}"
  for _attempt in 1 2; do
    PLAN_JSON="$(jq -nc --arg n "$N_BACKUP_PLAN" --arg v "$N_BACKUP_VAULT" \
      --argjson d "$DAILY" --argjson w "$WEEKLY" \
      '{BackupPlanName:$n, Rules:[
         {RuleName:"daily", TargetBackupVaultName:$v,
          ScheduleExpression:"cron(0 17 * * ? *)",
          StartWindowMinutes:60, CompletionWindowMinutes:180,
          Lifecycle:{DeleteAfterDays:$d}},
         {RuleName:"weekly", TargetBackupVaultName:$v,
          ScheduleExpression:"cron(0 18 ? * SUN *)",
          StartWindowMinutes:60, CompletionWindowMinutes:360,
          Lifecycle:{DeleteAfterDays:$w}}]}')"
    if BERR="$(aws backup create-backup-plan --backup-plan "$PLAN_JSON" \
                --backup-plan-tags Project=capstone,Owner="$PREFIX" \
                --query BackupPlanId --output text 2>&1)"; then
      PLAN_ID="$BERR"
      ok "백업 계획 생성: $N_BACKUP_PLAN (일 ${DAILY}일 / 주 ${WEEKLY}일 보존)"
      break
    fi
    case "$BERR" in
      *FreeTier*|*retention*|*Retention*)
        warn "보존 기간 제약 — 짧게 재시도합니다"; DAILY=7; WEEKLY=14 ;;
      *AlreadyExists*)
        PLAN_ID="$(_q aws backup list-backup-plans \
          --query "BackupPlansList[?BackupPlanName=='$N_BACKUP_PLAN'].BackupPlanId | [0]" --output text)"
        skip "백업 계획 (이미 존재)"; break ;;
      *) err "백업 계획 생성 실패"; printf '      %s\n' "$BERR" >&2; exit 1 ;;
    esac
  done
  [ -n "$PLAN_ID" ] || die "백업 계획을 만들지 못했습니다"
else
  skip "백업 계획 ($PLAN_ID)"
fi
save_state BACKUP_PLAN_ID "$PLAN_ID"

# ---------- 4. 태그 기반 리소스 선택 ----------
# 리소스를 하나씩 지정하지 않고 태그로 묶는다.
# 앞으로 만들 리소스도 태그만 맞으면 자동으로 보호 대상이 된다.
SEL_N="$(_q aws backup list-backup-selections --backup-plan-id "$PLAN_ID" \
        --query "length(BackupSelectionsList[?SelectionName=='${PREFIX}-tagged'])" --output text)"
if [ "${SEL_N:-0}" = "0" ]; then
  SEL_JSON="$(jq -nc --arg name "${PREFIX}-tagged" --arg r "$B_ROLE_ARN" --arg p "$PREFIX" \
    '{SelectionName:$name, IamRoleArn:$r,
      ListOfTags:[{ConditionType:"STRINGEQUALS",ConditionKey:"Project",ConditionValue:"capstone"},
                  {ConditionType:"STRINGEQUALS",ConditionKey:"Owner",ConditionValue:$p}]}')"
  # 방금 만든 역할은 Backup 이 아직 맡을 수 없다. 전파를 기다리며 재시도한다.
  SEL_OK=0
  for _try in 1 2 3 4 5 6; do
    if SERR="$(aws backup create-backup-selection --backup-plan-id "$PLAN_ID" \
                --backup-selection "$SEL_JSON" 2>&1 >/dev/null)"; then
      ok "태그 기반 선택 생성 (Project=capstone, Owner=$PREFIX)"
      SEL_OK=1; break
    fi
    case "$SERR" in
      *AlreadyExists*|*already\ exists*) skip "백업 선택 (이미 존재)"; SEL_OK=1; break ;;
      *"cannot be assumed"*|*AccessDenied*|*"not authorized"*|*InvalidParameterValue*)
        log "  Backup 역할 전파 대기 (${_try}/6)"; sleep 10 ;;
      *) err "백업 선택 생성 실패"; printf '      %s\n' "$SERR" >&2; break ;;
    esac
  done
  [ "$SEL_OK" = "1" ] || warn "백업 선택을 만들지 못했습니다. 잠시 후 build.sh 를 다시 실행하십시오."
else
  skip "백업 선택"
fi

# ---------- 5. 온디맨드 백업 (선택) ----------
# DB 배포 방식에 따라 리소스 ARN 이 다르다.
if [ "${RUN_ONDEMAND:-0}" = "1" ]; then
  if [ "${DB_MODE_USED:-$DB_MODE}" = "rds" ] && [ -n "${DB_IDENTIFIER:-}" ]; then
    RES_ARN="arn:aws:rds:${REGION}:${ACCOUNT_ID}:db:${DB_IDENTIFIER}"
  elif [ -n "${AURORA_CLUSTER:-}" ]; then
    RES_ARN="arn:aws:rds:${REGION}:${ACCOUNT_ID}:cluster:${AURORA_CLUSTER}"
  else
    RES_ARN=""
  fi
  if [ -n "$RES_ARN" ]; then
    JOB="$(_q aws backup start-backup-job --backup-vault-name "$N_BACKUP_VAULT" \
          --resource-arn "$RES_ARN" --iam-role-arn "$B_ROLE_ARN" \
          --lifecycle DeleteAfterDays=7 --query BackupJobId --output text)"
    if [ -n "$JOB" ]; then
      save_state BACKUP_JOB_ID "$JOB"
      ok "온디맨드 백업 시작: $JOB"
      log "  진행 확인: aws backup describe-backup-job --backup-job-id $JOB --query State --output text"
    else
      warn "온디맨드 백업 시작 실패 — 역할 전파를 기다린 뒤 재시도하십시오"
    fi
  else
    warn "DB 리소스 ARN 을 확정할 수 없어 온디맨드 백업을 건너뜁니다"
  fi
else
  log "RUN_ONDEMAND=1 로 실행하면 DB 온디맨드 백업을 즉시 수행합니다."
fi

save_state LAB13_DONE 1
ok "Lab 13 백업 구성 완료"

# ============================================================
# 캡스톤 전체 통합 검증
# ============================================================
banner "캡스톤 종단 간 검증 — Lab 1~13"

PASS=0; FAIL=0; SKIP=0
t() { # t <설명> <판정명령...>
  local d="$1"; shift
  printf '  %-40s' "$d"
  if "$@" >/dev/null 2>&1; then printf '%sOK%s\n' "$C_G" "$C_0"; PASS=$((PASS+1))
  else printf '%sNG%s\n' "$C_R" "$C_0"; FAIL=$((FAIL+1)); fi
}
s() { # 전제가 없어 건너뛰는 항목
  SKIP=$((SKIP+1))
  printf '  %-40s' "$1"
  printf '%sSKIP%s  %s\n' "$C_Y" "$C_0" "$2"
}

# 판정은 모두 함수로 분리한다. bash -c 안에 인용을 겹치면 반드시 깨진다.
cnt() { aws "$@" --output text 2>/dev/null | tr -d '[:space:]'; }
ge()  { [ "${1:-0}" -ge "${2:-1}" ] 2>/dev/null; }
eq()  { [ "${1:-}" = "${2:-}" ]; }

n_vpc()     { cnt ec2 describe-vpcs    --filters "Name=tag:Owner,Values=$PREFIX" --query 'length(Vpcs)'; }
n_subnet()  { cnt ec2 describe-subnets --filters "Name=tag:Owner,Values=$PREFIX" --query 'length(Subnets)'; }
n_nat()     { cnt ec2 describe-nat-gateways --filter "Name=tag:Owner,Values=$PREFIX" "Name=state,Values=available" --query 'length(NatGateways)'; }
n_tgwatt()  { cnt ec2 describe-transit-gateway-attachments --filters "Name=transit-gateway-id,Values=${TGW_ID:-none}" "Name=state,Values=available" --query 'length(TransitGatewayAttachments)'; }
n_asg()     { cnt autoscaling describe-auto-scaling-groups --auto-scaling-group-names "${ASG_NAME:-none}" --query 'length(AutoScalingGroups[0].Instances)'; }
n_efsmt()   { cnt efs describe-mount-targets --file-system-id "${EFS_ID:-none}" --query "length(MountTargets[?LifeCycleState=='available'])"; }
n_flow()    { cnt ec2 describe-flow-logs --query "length(FlowLogs[?FlowLogStatus=='ACTIVE'])"; }
n_sel()     { cnt backup list-backup-selections --backup-plan-id "$PLAN_ID" --query 'length(BackupSelectionsList)'; }
v_rds()     { cnt rds describe-db-instances --db-instance-identifier "${DB_IDENTIFIER:-none}" --query 'DBInstances[0].DBInstanceStatus'; }
v_rdsmaz()  { cnt rds describe-db-instances --db-instance-identifier "${DB_IDENTIFIER:-none}" --query 'DBInstances[0].MultiAZ'; }
v_aurora()  { cnt rds describe-db-clusters  --db-cluster-identifier "${AURORA_CLUSTER:-none}" --query 'DBClusters[0].Status'; }
v_trail()   { cnt cloudtrail get-trail-status --name "${TRAIL_NAME:-none}" --query 'IsLogging'; }
http_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$1" 2>/dev/null; }
body_has()  { curl -fsS --max-time 25 "$1" 2>/dev/null | grep -qEi -- "$2"; }

printf '\n%s[네트워크 기반]%s\n' "$C_B" "$C_0"
t "VPC 2개 존재"            eq "$(n_vpc)" 2
t "서브넷 12개 존재"        eq "$(n_subnet)" 12
t "NAT 게이트웨이 available" ge "$(n_nat)" 1
if [ -n "${TGW_ID:-}" ]; then t "TGW 어태치먼트 2개" eq "$(n_tgwatt)" 2
else s "TGW 어태치먼트 2개" "Lab 5 미구성"; fi
if [ -n "${VPCE_S3:-}" ]; then t "S3 게이트웨이 엔드포인트" aws ec2 describe-vpc-endpoints --vpc-endpoint-ids "$VPCE_S3"
else s "S3 게이트웨이 엔드포인트" "Lab 5 미구성"; fi

printf '\n%s[컴퓨팅·스토리지]%s\n' "$C_B" "$C_0"
if [ -n "${ASG_NAME:-}" ]; then t "ASG 노드 2개 이상" ge "$(n_asg)" 2
else s "ASG 노드" "Lab 10 미구성"; fi
if [ -n "${EFS_ID:-}" ]; then t "EFS 마운트 대상 2개" eq "$(n_efsmt)" 2
else s "EFS 마운트 대상" "Lab 7 미구성"; fi

printf '\n%s[데이터베이스]%s\n' "$C_B" "$C_0"
if [ "${DB_MODE_USED:-$DB_MODE}" = "rds" ] && [ -n "${DB_IDENTIFIER:-}" ]; then
  t "RDS available" eq "$(v_rds)" available
  t "RDS 다중 AZ"   eq "$(v_rdsmaz)" True
elif [ -n "${AURORA_CLUSTER:-}" ]; then
  t "Aurora 클러스터 available" eq "$(v_aurora)" available
else s "데이터베이스" "Lab 8 미구성"; fi

printf '\n%s[트래픽 경로]%s\n' "$C_B" "$C_0"
if [ -n "${ALB_DNS:-}" ]; then
  t "ALB 상태 검사 응답"     body_has "http://${ALB_DNS}/health" OK
  t "ALB → Tomcat → DB"      body_has "http://${ALB_DNS}/" 'DB_STATUS</th><td>OK'
else s "ALB 경로" "Lab 10 미구성"; fi
if [ -n "${CLOUDFRONT_DOMAIN:-}" ]; then
  t "CloudFront → 동적(ALB)"  body_has "https://${CLOUDFRONT_DOMAIN}/health" OK
  # 본문 문구는 랩마다 다를 수 있다. 상태 코드와 오리진 헤더로 판정한다.
  cf_static_ok() {
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 25 "https://${CLOUDFRONT_DOMAIN}/static/index.html")"
    [ "$code" = "200" ]
  }
  t "CloudFront → 정적(S3)"   cf_static_ok
  t "CloudFront → WAF 차단"   eq "$(http_code "https://${CLOUDFRONT_DOMAIN}/?q=%3Cscript%3E")" 403
else s "CloudFront 경로" "Lab 11 미구성"; fi
if [ -n "${APIGW_ENDPOINT:-}" ]; then
  t "API Gateway → Lambda"    body_has "${APIGW_ENDPOINT}/" capstone
else s "API Gateway 경로" "Lab 12 미구성"; fi

printf '\n%s[관측성·보호]%s\n' "$C_B" "$C_0"
if [ -n "${TRAIL_NAME:-}" ]; then t "CloudTrail 로깅 중" eq "$(v_trail)" True
else s "CloudTrail" "Lab 9 미구성"; fi
t "VPC Flow Logs ACTIVE" ge "$(n_flow)" 1
t "백업 계획 활성"       aws backup get-backup-plan --backup-plan-id "$PLAN_ID"
t "백업 대상 선택 존재"  ge "$(n_sel)" 1

printf '\n%s================================================================%s\n' "$C_B" "$C_0"
printf '  통과 %s%d%s  /  미충족 %s%d%s  /  건너뜀 %s%d%s\n' \
  "$C_G" "$PASS" "$C_0" "$([ "$FAIL" -gt 0 ] && printf '%s' "$C_R" || printf '%s' "$C_G")" "$FAIL" "$C_0" "$C_Y" "$SKIP" "$C_0"
printf '%s================================================================%s\n\n' "$C_B" "$C_0"

if [ "$FAIL" -eq 0 ]; then
  ok "캡스톤 아키텍처 종단 간 검증 통과"
else
  err "미충족 항목 ${FAIL}개 — 해당 랩의 verify.sh 로 상세를 확인하십시오"
  log "  전체 진단: bash verify-all.sh"
fi

banner "다음으로 할 것"
cat << 'GUIDE'
  복구 실습 — 백업만 만들고 복원해 보지 않으면 백업이 아니다
    1) 온디맨드 백업 수행
         RUN_ONDEMAND=1 bash lab13-backup/build.sh
    2) 복구 지점 확인
         aws backup list-recovery-points-by-backup-vault --backup-vault-name <볼트> \
           --query 'RecoveryPoints[].{Arn:RecoveryPointArn,Status:Status,Created:CreationDate}' --output table
    3) DB 스냅샷 복원 (새 인스턴스로)
         aws backup start-restore-job --recovery-point-arn <ARN> --iam-role-arn <역할> \
           --metadata '{"DBInstanceIdentifier":"cap-rds-restored"}' --resource-type RDS

  RPO/RTO 정리 — 서비스별로 표를 만들어 보십시오
    EC2(ASG)  : 노드가 죽어도 자동 대체 → RPO 0 / RTO 3~5분
    EFS       : 다중 AZ 복제           → RPO 0 / RTO 0
    RDS 다중AZ: 동기 복제 + 자동 승격  → RPO 0 / RTO 1~2분
    S3        : 버전 관리              → RPO 0 / RTO 즉시
    전체 삭제 : AWS Backup 복원        → RPO 24시간 / RTO 수십 분

  비용 정리 — 실습이 끝났다면
    bash teardown-all.sh
GUIDE
