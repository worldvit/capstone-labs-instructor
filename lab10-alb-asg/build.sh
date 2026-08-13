#!/usr/bin/env bash
# Lab 10 — ALB + Auto Scaling Group + EFS
#
# Lab 8.5의 3-Tier 는 nginx 1대가 단일 장애점이었다. 여기서 그것을 제거한다.
#
#   변경 전:  인터넷 → nginx(1대) → Tomcat(고정 2대) → PostgreSQL
#   변경 후:  인터넷 → ALB(다중 AZ) → Tomcat(ASG 2~4대) → PostgreSQL
#                                        └ EFS 공유 스토리지
#
# ASG 노드는 부팅 시 스스로 Tomcat·JDBC·EFS를 구성한다(사용자 데이터).
# 수동 설치한 Lab 4의 app-a/app-c 와 달리, 언제 늘어나도 같은 상태가 된다.
source "$(dirname "$0")/../00-common/bootstrap.sh"
guard
banner "Lab 10 build — ALB + Auto Scaling Group + EFS"
LAB=10
need_state VPC_SVC SN_SVC_PUB_A SN_SVC_PUB_C SN_SVC_APP_A SN_SVC_APP_C SG_ALB SG_APP PROFILE_EC2

HERE="$(cd "$(dirname "$0")" && pwd)"
DBEP="${DB_ENDPOINT:-${AURORA_WRITER_EP:-}}"
DBPORT="${DB_PORT_USED:-5432}"
DBNAME="${DB_NAME:-postgres}"
APP_PORT="${APP_PORT:-8080}"      # Tomcat 포트. Lab 8.5와 같아야 한다.

[ -n "$DBEP" ] || warn "DB 엔드포인트 없음 — 노드의 DB 조회는 실패합니다"
[ -n "${EFS_ID:-}" ] || warn "EFS_ID 없음 — 공유 스토리지 없이 진행합니다(Lab 7 확인)"

# ---------- 1. 보안 그룹 경로 ----------
# ALB → Tomcat 8080. Lab 8.5는 web-sg(nginx)에서 8080을 열었고,
# 여기서는 alb-sg 도 8080을 쓸 수 있게 한다. 두 경로가 잠시 공존한다.
_authz() { # <설명> <group-id> <ip-permissions>
  local desc="$1" gid="$2" perm="$3" e
  e="$(aws ec2 authorize-security-group-ingress --group-id "$gid" --ip-permissions "$perm" 2>&1 >/dev/null)" \
    && { ok "  $desc"; return 0; }
  case "$e" in
    *InvalidPermission.Duplicate*) skip "  $desc"; return 0 ;;
    *) err "  $desc — 실패"; printf '      %s\n' "$e" >&2; return 1 ;;
  esac
}
_authz "app-sg 인바운드 ${APP_PORT} from alb-sg" "$SG_APP" \
  "IpProtocol=tcp,FromPort=${APP_PORT},ToPort=${APP_PORT},UserIdGroupPairs=[{GroupId=$SG_ALB}]"
# EFS 는 ASG 노드도 마운트한다. efs-sg 는 app-sg 를 이미 허용하므로 추가 작업이 없다.

# ---------- 2. 시작 템플릿 ----------
AMI="$(latest_ami)"
ok "AMI(SSM 파라미터 조회): $AMI"

TMP_UD="$(mktemp)"
sed -e "s|__DB_SECRET_ARN__|${DB_SECRET_ARN:-}|" \
    -e "s|__DB_ENDPOINT__|${DBEP}|" \
    -e "s|__DB_PORT__|${DBPORT}|" \
    -e "s|__DB_NAME__|${DBNAME}|" \
    -e "s|__REGION__|${REGION}|" \
    -e "s|__EFS_ID__|${EFS_ID:-none}|" \
    "$HERE/setup-app-node.sh" > "$TMP_UD"
UD_B64="$(base64 -w0 < "$TMP_UD")"
rm -f "$TMP_UD"
log "사용자 데이터 크기: ${#UD_B64} bytes (한도 16384)"
[ "${#UD_B64}" -lt 16000 ] || die "사용자 데이터가 한도를 넘습니다. 스크립트를 줄이십시오."

# 시작 템플릿 데이터는 jq 로 만든다. heredoc 으로 JSON 을 짜면 반드시 어긋난다.
LT_DATA="$(jq -nc \
  --arg ami "$AMI" --arg itype "$INSTANCE_TYPE" --arg prof "$N_PROFILE_EC2" \
  --arg sg "$SG_APP" --arg ud "$UD_B64" --arg name "${PREFIX}-asg-node" \
  --arg prefix "$PREFIX" --arg lab "$LAB" \
  --argjson mon "$([ "$DETAILED_MONITORING" = "true" ] && echo true || echo false)" \
  '{ImageId:$ami, InstanceType:$itype,
    IamInstanceProfile:{Name:$prof},
    SecurityGroupIds:[$sg],
    MetadataOptions:{HttpTokens:"required",HttpEndpoint:"enabled"},
    Monitoring:{Enabled:$mon},
    UserData:$ud,
    TagSpecifications:[{ResourceType:"instance",
      Tags:[{Key:"Name",Value:$name},{Key:"Project",Value:"capstone"},
            {Key:"Lab",Value:$lab},{Key:"Owner",Value:$prefix},{Key:"Tier",Value:"app"}]}]}')"
printf '%s' "$LT_DATA" | jq -e . >/dev/null || die "시작 템플릿 JSON 생성 실패"

if aws ec2 describe-launch-templates --launch-template-names "$N_LT" >/dev/null 2>&1; then
  VER="$(aws ec2 create-launch-template-version --launch-template-name "$N_LT" \
        --launch-template-data "$LT_DATA" \
        --query 'LaunchTemplateVersion.VersionNumber' --output text)"
  aws ec2 modify-launch-template --launch-template-name "$N_LT" --default-version "$VER" >/dev/null
  ok "시작 템플릿 새 버전 생성: $N_LT (v$VER, 기본 버전으로 지정)"
else
  aws ec2 create-launch-template --launch-template-name "$N_LT" \
    --launch-template-data "$LT_DATA" \
    --tag-specifications "$(tagspec launch-template "$N_LT" $LAB)" >/dev/null
  ok "시작 템플릿 생성: $N_LT"
fi
save_state LAUNCH_TEMPLATE "$N_LT"

# ---------- 3. 대상 그룹 ----------
TG_ARN="$(_q aws elbv2 describe-target-groups --names "$N_TG" --query 'TargetGroups[0].TargetGroupArn' --output text)"
if [ -z "$TG_ARN" ]; then
  TG_ARN="$(aws elbv2 create-target-group --name "$N_TG" \
    --protocol HTTP --port "$APP_PORT" --vpc-id "$VPC_SVC" --target-type instance \
    --health-check-protocol HTTP --health-check-path /health \
    --health-check-interval-seconds 15 --health-check-timeout-seconds 5 \
    --healthy-threshold-count 2 --unhealthy-threshold-count 3 \
    --matcher HttpCode=200 \
    --tags Key=Project,Value=capstone Key=Lab,Value=$LAB Key=Owner,Value="$PREFIX" \
    --query 'TargetGroups[0].TargetGroupArn' --output text)"
  ok "대상 그룹 생성: $N_TG (HTTP:${APP_PORT}, 상태 검사 /health)"
else
  skip "대상 그룹 $N_TG"
fi
# 등록 해제 지연을 줄여 스케일 인 실습이 빨리 끝나게 한다(기본 300초).
aws elbv2 modify-target-group-attributes --target-group-arn "$TG_ARN" \
  --attributes Key=deregistration_delay.timeout_seconds,Value=30 >/dev/null 2>&1 || true
save_state TARGET_GROUP_ARN "$TG_ARN"

# ---------- 4. ALB ----------
ALB_ARN="$(_q aws elbv2 describe-load-balancers --names "$N_ALB" --query 'LoadBalancers[0].LoadBalancerArn' --output text)"
if [ -z "$ALB_ARN" ]; then
  ALB_ARN="$(aws elbv2 create-load-balancer --name "$N_ALB" --type application --scheme internet-facing \
    --subnets "$SN_SVC_PUB_A" "$SN_SVC_PUB_C" --security-groups "$SG_ALB" \
    --tags Key=Project,Value=capstone Key=Lab,Value=$LAB Key=Owner,Value="$PREFIX" \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text)"
  ok "ALB 생성: $N_ALB (2개 AZ)"
else
  skip "ALB $N_ALB"
fi
save_state ALB_ARN "$ALB_ARN"

log "ALB active 대기"
aws elbv2 wait load-balancer-available --load-balancer-arns "$ALB_ARN"
ALB_DNS="$(_q aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" --query 'LoadBalancers[0].DNSName' --output text)"
save_state ALB_DNS "$ALB_DNS"
ok "ALB DNS: $ALB_DNS"

LSN="$(_q aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" --query 'Listeners[0].ListenerArn' --output text)"
if [ -z "$LSN" ]; then
  LSN="$(aws elbv2 create-listener --load-balancer-arn "$ALB_ARN" --protocol HTTP --port 80 \
    --default-actions "Type=forward,TargetGroupArn=$TG_ARN" \
    --query 'Listeners[0].ListenerArn' --output text)"
  ok "리스너 생성 (HTTP:80 → ${N_TG}:${APP_PORT})"
else
  skip "리스너"
fi
save_state ALB_LISTENER_ARN "$LSN"

# ---------- 5. Auto Scaling Group ----------
ASG_EXISTS="$(_q aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$N_ASG" \
              --query 'length(AutoScalingGroups)' --output text)"
if [ "${ASG_EXISTS:-0}" = "1" ]; then
  aws autoscaling update-auto-scaling-group --auto-scaling-group-name "$N_ASG" \
    --launch-template "LaunchTemplateName=$N_LT,Version=\$Latest" \
    --min-size 2 --max-size 4 --desired-capacity 2 \
    --default-cooldown "$ASG_COOLDOWN" \
    --health-check-type ELB --health-check-grace-period 300 >/dev/null
  skip "ASG $N_ASG (설정 갱신)"
  # 새 시작 템플릿을 반영하려면 인스턴스를 교체해야 한다.
  if [ "${REFRESH_ASG:-0}" = "1" ]; then
    aws autoscaling start-instance-refresh --auto-scaling-group-name "$N_ASG" \
      --preferences "MinHealthyPercentage=50,InstanceWarmup=300" >/dev/null 2>&1 \
      && ok "인스턴스 새로 고침 시작 (새 템플릿 반영)" || warn "새로 고침 시작 실패"
  else
    log "REFRESH_ASG=1 로 실행하면 기존 노드를 새 템플릿으로 교체합니다."
  fi
else
  aws autoscaling create-auto-scaling-group --auto-scaling-group-name "$N_ASG" \
    --launch-template "LaunchTemplateName=$N_LT,Version=\$Latest" \
    --min-size 2 --max-size 4 --desired-capacity 2 \
    --vpc-zone-identifier "${SN_SVC_APP_A},${SN_SVC_APP_C}" \
    --target-group-arns "$TG_ARN" \
    --default-cooldown "$ASG_COOLDOWN" \
    --health-check-type ELB --health-check-grace-period 300 \
    --tags "Key=Name,Value=${PREFIX}-asg-node,PropagateAtLaunch=true" \
           "Key=Project,Value=capstone,PropagateAtLaunch=true" \
           "Key=Owner,Value=${PREFIX},PropagateAtLaunch=true" \
           "Key=Tier,Value=app,PropagateAtLaunch=true" >/dev/null
  ok "ASG 생성: $N_ASG (min 2 / desired 2 / max 4, 2개 AZ)"
fi
save_state ASG_NAME "$N_ASG"

# ---------- 6. 조정 정책 ----------
# ASG를 갓 만들면 서비스 연결 역할이 준비되지 않아 ServiceLinkedRoleFailure 가 난다. 재시도한다.
POL_CFG="$(jq -nc --argjson tv "$SCALE_TARGET_CPU" --argjson warm "$ASG_WARMUP" \
  '{PredefinedMetricSpecification:{PredefinedMetricType:"ASGAverageCPUUtilization"},
    TargetValue:$tv, DisableScaleIn:false}')"

POL_OK=0
for attempt in 1 2 3 4 5; do
  if PERR="$(aws autoscaling put-scaling-policy --auto-scaling-group-name "$N_ASG" \
              --policy-name "${PREFIX}-cpu-target" --policy-type TargetTrackingScaling \
              --estimated-instance-warmup "$ASG_WARMUP" \
              --target-tracking-configuration "$POL_CFG" 2>&1 >/dev/null)"; then
    ok "조정 정책: 평균 CPU ${SCALE_TARGET_CPU}% 목표 (워밍업 ${ASG_WARMUP}초)"
    POL_OK=1; break
  fi
  case "$PERR" in
    *ServiceLinkedRoleFailure*|*"not yet ready"*)
      log "  서비스 연결 역할 준비 대기 (${attempt}/5)"; sleep 20 ;;
    *) err "조정 정책 생성 실패"; printf '      %s\n' "$PERR" >&2; break ;;
  esac
done
[ "$POL_OK" = "1" ] || warn "조정 정책이 없습니다. 잠시 후 bash lab10-alb-asg/build.sh 를 다시 실행하십시오."

if [ "$DETAILED_MONITORING" = "true" ]; then
  ok "세부 모니터링 활성 — 지표가 1분 간격이라 3분이면 조정이 반응합니다"
else
  warn "기본 모니터링(5분) — 조정 반응까지 최소 15분 걸립니다. DETAILED_MONITORING=true 권장"
fi

# ---------- 7. 대상 healthy 대기 ----------
log "대상 healthy 대기 (노드 부팅 + Tomcat 기동으로 5~8분 소요)"
wait_until "healthy 대상 2개" 900 20 bash -c \
  "[ \"\$(aws elbv2 describe-target-health --target-group-arn $TG_ARN \
     --query \"length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])\" --output text)\" -ge 2 ]" \
  || {
    warn "healthy 대상 확인 실패. 아래로 진단하십시오."
    warn "  대상 상태: aws elbv2 describe-target-health --target-group-arn $TG_ARN --output table"
    warn "  노드 로그: aws ssm send-command --instance-ids <id> --document-name AWS-RunShellScript \\"
    warn "               --parameters 'commands=[\"tail -50 /var/log/capstone-bootstrap.log\"]'"
  }

# ---------- 8. nginx 폐기 안내 ----------
if [ -n "${NGINX_ID:-}" ]; then
  if [ "${DECOMMISSION_NGINX:-0}" = "1" ]; then
    aws ssm send-command --instance-ids "$NGINX_ID" --document-name AWS-RunShellScript \
      --parameters "$(jq -nc '{commands:["systemctl stop nginx; systemctl disable nginx"]}')" >/dev/null 2>&1 \
      && ok "nginx 중지 — ALB 가 Web 계층을 대체합니다" || warn "nginx 중지 실패"
    save_state NGINX_DECOMMISSIONED 1
  else
    log "nginx(${NGINX_ID}) 는 아직 살아 있습니다. 비교 실습 후 폐기하십시오."
    log "  DECOMMISSION_NGINX=1 bash lab10-alb-asg/build.sh"
  fi
fi

save_state APP_PORT_USED "$APP_PORT"
save_state LAB10_DONE 1

banner "구성 완료"
cat << GUIDE
  ALB 주소:  http://${ALB_DNS}/
  nginx 주소: http://${NGINX_IP:-없음}/   (Lab 8.5, 비교용)

  확인할 것
    1) ALB 를 통해 ASG 노드가 응답하는가
         curl -s http://${ALB_DNS}/ | grep -E 'APP_INSTANCE|LAUNCHED_BY'
       LAUNCHED_BY 가 ASG 이면 Auto Scaling 이 만든 노드다.

    2) 두 AZ 에 분산되는가
         for i in \$(seq 1 8); do curl -s -H 'Connection: close' http://${ALB_DNS}/ \\
           | sed -n 's|.*APP_AZ</th><td>\\([^<]*\\).*|\\1|p'; done | sort | uniq -c

    3) EFS 공유가 동작하는가
         curl -s http://${ALB_DNS}/ | grep EFS_SHARED_NOTE
       모든 노드가 같은 문자열을 보여야 한다. 이것이 EFS 를 쓰는 이유다.

    4) 단일 장애점이 사라졌는가 — 노드 하나를 종료해도 서비스가 유지된다
         ID=\$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names ${N_ASG} \\
              --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)
         aws ec2 terminate-instances --instance-ids \$ID
         while true; do curl -s -o /dev/null -w "%{http_code} " http://${ALB_DNS}/; sleep 3; done

    5) 확장이 동작하는가 — 부하를 주면 노드가 늘어난다
         bash lab10-alb-asg/loadtest.sh
GUIDE
ok "Lab 10 완료"
