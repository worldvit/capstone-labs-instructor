#!/usr/bin/env bash
# Lab 8.5 — 전통적 3-Tier 구성
#
#   인터넷 → nginx(퍼블릭 서브넷) → Tomcat(App 서브넷) → PostgreSQL(DB 서브넷)
#
# ALB 없이 구성한다. Lab 10에서 ALB·ASG를 얹으며 nginx 단일 장애점을 제거한다.
# 보안 그룹 체인:  web-sg(80) → app-sg(8080) → db-sg(5432)
source "$(dirname "$0")/../00-common/bootstrap.sh"
guard
banner "Lab 8.5 build — 3-Tier 기본 (nginx → Tomcat → PostgreSQL)"
LAB=8

need_state VPC_SVC SN_SVC_PUB_A SG_APP PROFILE_EC2 APP_A_ID APP_C_ID
DBEP="${DB_ENDPOINT:-${AURORA_WRITER_EP:-}}"
[ -n "$DBEP" ] || die "DB 엔드포인트를 찾을 수 없습니다. Lab 8을 먼저 실행하십시오."
DBPORT="${DB_PORT_USED:-5432}"
DBNAME="${DB_NAME:-postgres}"

HERE="$(cd "$(dirname "$0")" && pwd)"
# 인터넷에서 nginx로의 접근을 허용할 대역. 강의장 IP로 좁히는 것을 권장한다.
WEB_CIDR="${WEB_CIDR:-0.0.0.0/0}"

# ---------- 1. web-sg ----------
SG_WEB_ID="$(_q aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=${PREFIX}-sg-web" "Name=vpc-id,Values=$VPC_SVC" \
  --query 'SecurityGroups[0].GroupId' --output text)"
if [ -z "$SG_WEB_ID" ]; then
  SG_WEB_ID="$(aws ec2 create-security-group --group-name "${PREFIX}-sg-web" \
    --description "capstone web tier (nginx)" --vpc-id "$VPC_SVC" \
    --tag-specifications "$(tagspec security-group "${PREFIX}-sg-web" $LAB)" \
    --query 'GroupId' --output text)"
  ok "SG 생성: ${PREFIX}-sg-web ($SG_WEB_ID)"
else
  skip "SG ${PREFIX}-sg-web ($SG_WEB_ID)"
fi
save_state SG_WEB "$SG_WEB_ID"

_authz() { # <설명> <group-id> <ip-permissions>
  local desc="$1" gid="$2" perm="$3" e
  e="$(aws ec2 authorize-security-group-ingress --group-id "$gid" --ip-permissions "$perm" 2>&1 >/dev/null)" \
    && { ok "  $desc"; return 0; }
  case "$e" in
    *InvalidPermission.Duplicate*) skip "  $desc"; return 0 ;;
    *) err "  $desc — 실패"; printf '      %s\n' "$e" >&2; return 1 ;;
  esac
}
_authz "인바운드 80 from $WEB_CIDR" "$SG_WEB_ID" \
  "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=$WEB_CIDR}]"
_authz "인바운드 22 from 관리 VPC" "$SG_WEB_ID" \
  "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=$VPC_MGMT_CIDR}]"

# App 계층은 Web 계층에서만 8080을 받는다. 인터넷에서 직접 8080은 열지 않는다.
_authz "app-sg 인바운드 8080 from web-sg" "$SG_APP" \
  "IpProtocol=tcp,FromPort=8080,ToPort=8080,UserIdGroupPairs=[{GroupId=$SG_WEB_ID}]"

# ---------- 2. EC2 역할에 시크릿 읽기 권한 ----------
# Tomcat이 DB 비밀번호를 Secrets Manager에서 직접 읽는다. 파일이나 코드에 남기지 않는다.
if [ -n "${DB_SECRET_ARN:-}" ]; then
  POL="$(jq -nc --arg a "$DB_SECRET_ARN" \
    '{Version:"2012-10-17",Statement:[{Sid:"ReadDbSecret",Effect:"Allow",Action:["secretsmanager:GetSecretValue"],Resource:$a}]}')"
  aws iam put-role-policy --role-name "$N_ROLE_EC2" \
    --policy-name "${PREFIX}-read-db-secret" --policy-document "$POL" >/dev/null \
    && ok "EC2 역할에 시크릿 읽기 권한 부여 (해당 시크릿만)" \
    || warn "시크릿 권한 부여 실패 — DB 조회가 실패할 수 있습니다"
else
  warn "DB_SECRET_ARN 없음 — DB 자격 증명을 가져올 수 없습니다"
fi

# ---------- 3. nginx EC2 ----------
AMI="$(latest_ami)"
NGINX_ID="$(instance_id_by_name "${PREFIX}-nginx")"
if [ -n "$NGINX_ID" ]; then
  skip "EC2 ${PREFIX}-nginx ($NGINX_ID)"
else
  NGINX_ID="$(aws ec2 run-instances --image-id "$AMI" --instance-type "$INSTANCE_TYPE" \
    --subnet-id "$SN_SVC_PUB_A" --security-group-ids "$SG_WEB_ID" \
    --associate-public-ip-address \
    --key-name "$N_KEYPAIR" --iam-instance-profile "Name=$N_PROFILE_EC2" \
    --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
    --tag-specifications "$(tagspec instance "${PREFIX}-nginx" $LAB)" \
    --query 'Instances[0].InstanceId' --output text)"
  ok "EC2 생성: ${PREFIX}-nginx ($NGINX_ID)"
fi
save_state NGINX_ID "$NGINX_ID"

log "인스턴스 running 대기"
aws ec2 wait instance-running --instance-ids "$NGINX_ID"
NGINX_IP="$(_q aws ec2 describe-instances --instance-ids "$NGINX_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
save_state NGINX_IP "$NGINX_IP"
ok "nginx 퍼블릭 IP: $NGINX_IP"

wait_until "nginx SSM 등록" 300 15 bash -c \
  "[ \"\$(aws ssm describe-instance-information --filters Key=InstanceIds,Values=$NGINX_ID --query 'length(InstanceInformationList)' --output text)\" = '1' ]" \
  || warn "SSM 등록 확인 실패 — 이후 구성 명령이 실패할 수 있습니다"

# ---------- 4. App 계층 구성 (Tomcat) ----------
ssm_send_script() { # <스크립트경로> <인스턴스ID...>
  local script="$1"; shift
  local b64 cid
  b64="$(base64 -w0 < "$script")"
  # 긴 스크립트를 SSM 파라미터에 그대로 넣으면 따옴표가 겹겹이 깨진다. base64로 넘긴다.
  cid="$(aws ssm send-command --instance-ids "$@" --document-name AWS-RunShellScript \
        --parameters "$(jq -nc --arg b "$b64" \
          '{commands:["echo \($b) | base64 -d > /tmp/capstone-setup.sh; bash /tmp/capstone-setup.sh"]}')" \
        --timeout-seconds 600 --query 'Command.CommandId' --output text)" || return 1
  printf '%s' "$cid"
}

ssm_wait() { # <command-id> <인스턴스ID...>
  local cid="$1"; shift
  wait_until "명령 완료" 600 10 bash -c \
    "s=\$(aws ssm list-command-invocations --command-id $cid --query 'CommandInvocations[].Status' --output text 2>/dev/null)
     case \"\$s\" in *InProgress*|*Pending*|'') exit 1 ;; *) exit 0 ;; esac" || true
  local fail=0 st
  for iid in "$@"; do
    st="$(_q aws ssm list-command-invocations --command-id "$cid" --instance-id "$iid" \
          --query 'CommandInvocations[0].Status' --output text)"
    if [ "$st" = "Success" ]; then ok "  성공: $iid"
    else
      err "  실패($st): $iid"
      aws ssm list-command-invocations --command-id "$cid" --instance-id "$iid" --details \
        --query 'CommandInvocations[0].CommandPlugins[0].Output' --output text 2>/dev/null | tail -15 | sed 's/^/      /'
      fail=1
    fi
  done
  return $fail
}

TMP_APP="$(mktemp)"
sed -e "s|__DB_SECRET_ARN__|${DB_SECRET_ARN:-}|" \
    -e "s|__DB_ENDPOINT__|${DBEP}|" \
    -e "s|__DB_PORT__|${DBPORT}|" \
    -e "s|__DB_NAME__|${DBNAME}|" \
    -e "s|__REGION__|${REGION}|" \
    "$HERE/setup-tomcat.sh" > "$TMP_APP"

log "App 계층 구성 (Tomcat + JDBC + JSP) — 3~5분 소요"
CID_APP="$(ssm_send_script "$TMP_APP" "$APP_A_ID" "$APP_C_ID")" \
  || die "App 계층 구성 명령 전송 실패"
save_state TOMCAT_CMD "$CID_APP"
ssm_wait "$CID_APP" "$APP_A_ID" "$APP_C_ID" || warn "일부 App 서버 구성이 실패했습니다"
rm -f "$TMP_APP"

# ---------- 5. Web 계층 구성 (nginx) ----------
APP_A_PIP="$(_q aws ec2 describe-instances --instance-ids "$APP_A_ID" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)"
APP_C_PIP="$(_q aws ec2 describe-instances --instance-ids "$APP_C_ID" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)"
[ -n "$APP_A_PIP" ] && [ -n "$APP_C_PIP" ] || die "App 서버 프라이빗 IP를 찾을 수 없습니다"
log "upstream 대상: $APP_A_PIP, $APP_C_PIP"

TMP_WEB="$(mktemp)"
sed -e "s|__UPSTREAMS__|${APP_A_PIP} ${APP_C_PIP}|" "$HERE/setup-nginx.sh" > "$TMP_WEB"

log "Web 계층 구성 (nginx 리버스 프록시) — 1~2분 소요"
CID_WEB="$(ssm_send_script "$TMP_WEB" "$NGINX_ID")" || die "Web 계층 구성 명령 전송 실패"
save_state NGINX_CMD "$CID_WEB"
ssm_wait "$CID_WEB" "$NGINX_ID" || warn "nginx 구성이 실패했습니다"
rm -f "$TMP_WEB"

save_state APP_A_PIP "$APP_A_PIP"
save_state APP_C_PIP "$APP_C_PIP"
save_state LAB08B_DONE 1

banner "3-Tier 구성 완료"
cat << GUIDE
  접속 주소: http://${NGINX_IP}/

  확인 순서
    1) 브라우저로 위 주소를 엽니다. APP_INSTANCE 와 DB_STATUS 가 보입니다.
    2) 새로고침해도 APP_INSTANCE 는 바뀌지 않습니다.
       nginx upstream 은 기본이 라운드로빈이지만 브라우저 연결 재사용 때문입니다.
       curl 로 반복하면 두 App 서버가 번갈아 응답합니다.
         for i in \$(seq 1 6); do curl -s http://${NGINX_IP}/ | grep APP_INSTANCE -A1 | tail -1; done
    3) App 계층에 인터넷에서 직접 접근되지 않는 것을 확인합니다.
         curl --max-time 5 http://${APP_A_PIP}:8080/   → 실패해야 정상(프라이빗 IP)
    4) 계층 구분
         http://${NGINX_IP}/web-health  → WEB_OK  (nginx 가 응답)
         http://${NGINX_IP}/health      → OK      (Tomcat 이 응답)
GUIDE
ok "Lab 8.5 완료"
