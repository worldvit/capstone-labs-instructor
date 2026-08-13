#!/usr/bin/env bash
# Lab 9 — CloudWatch / CloudTrail / VPC Flow Logs
source "$(dirname "$0")/../00-common/bootstrap.sh"
guard
banner "Lab 9 build — 관측성 3종"
LAB=9
need_state VPC_SVC BUCKET_LOGS

# ---------- 1. SNS 경보 주제 ----------
SNS_ARN="$(_q aws sns create-topic --name "$N_SNS_ALERTS" \
  --tags Key=Project,Value=capstone Key=Lab,Value=$LAB Key=Owner,Value="$PREFIX" \
  --query 'TopicArn' --output text)"
ok "SNS 주제: $SNS_ARN"
save_state SNS_ALERTS_ARN "$SNS_ARN"
if [ -n "$ALERT_EMAIL" ]; then
  aws sns subscribe --topic-arn "$SNS_ARN" --protocol email --notification-endpoint "$ALERT_EMAIL" >/dev/null 2>&1 \
    && ok "이메일 구독 요청: $ALERT_EMAIL (수신함에서 확인 필요)" || true
else
  warn "ALERT_EMAIL 미지정 — 이메일 구독을 건너뜁니다."
fi

# ---------- 2. CloudTrail ----------
cat > /tmp/${PREFIX}-trail-policy.json << JSON
{"Version":"2012-10-17","Statement":[
 {"Sid":"AWSCloudTrailAclCheck","Effect":"Allow","Principal":{"Service":"cloudtrail.amazonaws.com"},
  "Action":"s3:GetBucketAcl","Resource":"arn:aws:s3:::${BUCKET_LOGS}",
  "Condition":{"StringEquals":{"aws:SourceArn":"arn:aws:cloudtrail:${REGION}:${ACCOUNT_ID}:trail/${N_TRAIL}"}}},
 {"Sid":"AWSCloudTrailWrite","Effect":"Allow","Principal":{"Service":"cloudtrail.amazonaws.com"},
  "Action":"s3:PutObject","Resource":"arn:aws:s3:::${BUCKET_LOGS}/AWSLogs/${ACCOUNT_ID}/*",
  "Condition":{"StringEquals":{"s3:x-amz-acl":"bucket-owner-full-control",
   "aws:SourceArn":"arn:aws:cloudtrail:${REGION}:${ACCOUNT_ID}:trail/${N_TRAIL}"}}},
 {"Sid":"DenyInsecureTransport","Effect":"Deny","Principal":"*","Action":"s3:*",
  "Resource":["arn:aws:s3:::${BUCKET_LOGS}","arn:aws:s3:::${BUCKET_LOGS}/*"],
  "Condition":{"Bool":{"aws:SecureTransport":"false"}}}]}
JSON
aws s3api put-bucket-policy --bucket "$BUCKET_LOGS" --policy file:///tmp/${PREFIX}-trail-policy.json >/dev/null
ok "로그 버킷 정책 적용 (CloudTrail 쓰기 허용)"

if aws cloudtrail get-trail --name "$N_TRAIL" >/dev/null 2>&1; then
  skip "CloudTrail $N_TRAIL"
else
  aws cloudtrail create-trail --name "$N_TRAIL" --s3-bucket-name "$BUCKET_LOGS" \
    --is-multi-region-trail --enable-log-file-validation \
    --tags-list Key=Project,Value=capstone Key=Lab,Value=$LAB Key=Owner,Value="$PREFIX" >/dev/null
  ok "CloudTrail 생성: $N_TRAIL (다중 리전, 로그 파일 검증 활성)"
fi
aws cloudtrail start-logging --name "$N_TRAIL" >/dev/null 2>&1 && ok "CloudTrail 로깅 시작" || true
save_state TRAIL_NAME "$N_TRAIL"

# ---------- 3. VPC Flow Logs → CloudWatch Logs ----------
for LG in "$N_LOGGROUP_FLOW" "$N_LOGGROUP_APP"; do
  aws logs create-log-group --log-group-name "$LG" \
    --tags Project=capstone,Owner="$PREFIX" >/dev/null 2>&1 && ok "로그 그룹 생성: $LG" || skip "로그 그룹 $LG"
  aws logs put-retention-policy --log-group-name "$LG" --retention-in-days 30 >/dev/null 2>&1 || true
done

FL_TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"vpc-flow-logs.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
if aws iam get-role --role-name "$N_ROLE_FLOWLOG" >/dev/null 2>&1; then
  skip "역할 $N_ROLE_FLOWLOG"
else
  aws iam create-role --role-name "$N_ROLE_FLOWLOG" --assume-role-policy-document "$FL_TRUST" \
    --tags Key=Project,Value=capstone Key=Owner,Value="$PREFIX" >/dev/null
  ok "Flow Logs 역할 생성"
fi
aws iam put-role-policy --role-name "$N_ROLE_FLOWLOG" --policy-name flowlogs-write --policy-document \
 '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["logs:CreateLogStream","logs:PutLogEvents","logs:DescribeLogStreams","logs:DescribeLogGroups"],"Resource":"*"}]}' >/dev/null
FL_ROLE_ARN="$(_q aws iam get-role --role-name "$N_ROLE_FLOWLOG" --query 'Role.Arn' --output text)"
save_state FLOWLOG_ROLE_ARN "$FL_ROLE_ARN"

for V in "$VPC_SVC" "${VPC_MGMT:-}"; do
  [ -n "$V" ] || continue
  EXIST="$(_q aws ec2 describe-flow-logs --filter "Name=resource-id,Values=$V" --query 'FlowLogs[0].FlowLogId' --output text)"
  if [ -n "$EXIST" ]; then skip "Flow Log $V ($EXIST)"; continue; fi
  retry 6 10 aws ec2 create-flow-logs --resource-type VPC --resource-ids "$V" \
    --traffic-type ALL --log-destination-type cloud-watch-logs \
    --log-group-name "$N_LOGGROUP_FLOW" --deliver-logs-permission-arn "$FL_ROLE_ARN" \
    --max-aggregation-interval 60 \
    --tag-specifications "$(tagspec vpc-flow-log "${PREFIX}-flowlog" $LAB)" >/dev/null \
    && ok "Flow Log 생성: $V" || warn "Flow Log 생성 실패: $V (IAM 전파 지연 가능)"
done

# ---------- 4. 경보 ----------
mk_alarm() { # 이름 지표 네임스페이스 임계값 차원
  aws cloudwatch put-metric-alarm --alarm-name "$1" \
    --metric-name "$2" --namespace "$3" --statistic Average --period 300 \
    --evaluation-periods 2 --threshold "$4" --comparison-operator GreaterThanThreshold \
    --alarm-actions "$SNS_ARN" --treat-missing-data notBreaching \
    ${5:+--dimensions $5} \
    --tags Key=Project,Value=capstone Key=Owner,Value="$PREFIX" >/dev/null \
    && ok "경보 생성: $1" || warn "경보 생성 실패: $1"
}
[ -n "${APP_A_ID:-}" ] && mk_alarm "${PREFIX}-app-a-cpu-high" CPUUtilization AWS/EC2 70 "Name=InstanceId,Value=$APP_A_ID"
[ -n "${APP_C_ID:-}" ] && mk_alarm "${PREFIX}-app-c-cpu-high" CPUUtilization AWS/EC2 70 "Name=InstanceId,Value=$APP_C_ID"
# Web 계층(nginx)은 현재 단일 장애점이다. 반드시 감시 대상에 넣는다.
[ -n "${NGINX_ID:-}" ] && mk_alarm "${PREFIX}-nginx-cpu-high" CPUUtilization AWS/EC2 70 "Name=InstanceId,Value=$NGINX_ID"

# DB 지표의 차원은 배포 방식에 따라 다르다.
#   RDS 인스턴스 → DBInstanceIdentifier / Aurora 클러스터 → DBClusterIdentifier
if [ "${DB_MODE_USED:-$DB_MODE}" = "rds" ] && [ -n "${DB_IDENTIFIER:-}" ]; then
  DB_DIM="Name=DBInstanceIdentifier,Value=$DB_IDENTIFIER"
  mk_alarm "${PREFIX}-db-cpu-high"        CPUUtilization      AWS/RDS 80 "$DB_DIM"
  mk_alarm "${PREFIX}-db-connections-high" DatabaseConnections AWS/RDS 40 "$DB_DIM"
  save_state DB_ALARM_DIM "$DB_DIM"
elif [ -n "${AURORA_CLUSTER:-}" ]; then
  DB_DIM="Name=DBClusterIdentifier,Value=$AURORA_CLUSTER"
  mk_alarm "${PREFIX}-db-cpu-high"        CPUUtilization      AWS/RDS 80 "$DB_DIM"
  mk_alarm "${PREFIX}-db-connections-high" DatabaseConnections AWS/RDS 40 "$DB_DIM"
  save_state DB_ALARM_DIM "$DB_DIM"
else
  warn "DB 식별자를 찾을 수 없어 DB 경보를 건너뜁니다"
fi

# ---------- 5. CloudWatch Agent 배포 ----------
# 로그 그룹만 만들고 아무것도 보내지 않으면 관측성이 아니다. 실제로 수집한다.
HERE="$(cd "$(dirname "$0")" && pwd)"

ssm_send_script() { # <스크립트경로> <인스턴스ID...>
  local script="$1"; shift
  local b64
  b64="$(base64 -w0 < "$script")"
  aws ssm send-command --instance-ids "$@" --document-name AWS-RunShellScript \
    --parameters "$(jq -nc --arg b "$b64" \
      '{commands:["echo \($b) | base64 -d > /tmp/capstone-cw.sh; bash /tmp/capstone-cw.sh"]}')" \
    --timeout-seconds 600 --query 'Command.CommandId' --output text
}

ssm_wait() { # <command-id> <인스턴스ID...>
  local cid="$1"; shift
  wait_until "에이전트 구성 완료" 600 10 bash -c \
    "s=\$(aws ssm list-command-invocations --command-id $cid --query 'CommandInvocations[].Status' --output text 2>/dev/null)
     case \"\$s\" in *InProgress*|*Pending*|'') exit 1 ;; *) exit 0 ;; esac" || true
  local st
  for iid in "$@"; do
    st="$(_q aws ssm list-command-invocations --command-id "$cid" --instance-id "$iid" \
          --query 'CommandInvocations[0].Status' --output text)"
    if [ "$st" = "Success" ]; then ok "  성공: $iid"
    else
      warn "  실패($st): $iid"
      aws ssm list-command-invocations --command-id "$cid" --instance-id "$iid" --details \
        --query 'CommandInvocations[0].CommandPlugins[0].Output' --output text 2>/dev/null | tail -12 | sed 's/^/      /'
    fi
  done
}

deploy_cwagent() { # <역할 web|app> <인스턴스ID...>
  local role="$1"; shift
  [ $# -gt 0 ] || return 0
  local tmp; tmp="$(mktemp)"
  sed -e "s|__LG_APP__|${N_LOGGROUP_APP}|g" -e "s|__ROLE__|${role}|g" \
      "$HERE/setup-cwagent.sh" > "$tmp"
  log "CloudWatch Agent 배포 ($role): $*"
  local cid
  cid="$(ssm_send_script "$tmp" "$@")" || { warn "에이전트 배포 명령 전송 실패($role)"; rm -f "$tmp"; return 0; }
  ssm_wait "$cid" "$@"
  rm -f "$tmp"
  save_state "CWAGENT_CMD_${role}" "$cid"
}

APPIDS=()
[ -n "${APP_A_ID:-}" ] && APPIDS+=("$APP_A_ID")
[ -n "${APP_C_ID:-}" ] && APPIDS+=("$APP_C_ID")
[ ${#APPIDS[@]} -gt 0 ] && deploy_cwagent app "${APPIDS[@]}"
[ -n "${NGINX_ID:-}" ] && deploy_cwagent web "$NGINX_ID"

# ---------- 6. 대시보드 ----------
# 대시보드 JSON은 jq로 만든다.
# heredoc 안에서 정규식 백슬래시를 손으로 세면 반드시 어긋난다(실제로 어긋났다).
build_metric() { # <네임스페이스> <지표명> <차원키> <차원값> <라벨>
  jq -nc --arg ns "$1" --arg m "$2" --arg dk "$3" --arg dv "$4" --arg l "$5" \
    '[$ns,$m,$dk,$dv,{label:$l}]'
}

# EC2 위젯 — 3계층을 한눈에
EC2_M="$(jq -nc \
  --arg web "${NGINX_ID:-i-none}" --arg a "${APP_A_ID:-i-none}" --arg c "${APP_C_ID:-i-none}" \
  '[["AWS/EC2","CPUUtilization","InstanceId",$web,{label:"web/nginx"}],
    ["AWS/EC2","CPUUtilization","InstanceId",$a,{label:"app-a"}],
    ["AWS/EC2","CPUUtilization","InstanceId",$c,{label:"app-c"}]]')"

MEM_M="$(jq -nc \
  --arg web "${NGINX_ID:-i-none}" --arg a "${APP_A_ID:-i-none}" --arg c "${APP_C_ID:-i-none}" \
  '[["Capstone","MemoryUtilization","InstanceId",$web,{label:"web/nginx"}],
    ["Capstone","MemoryUtilization","InstanceId",$a,{label:"app-a"}],
    ["Capstone","MemoryUtilization","InstanceId",$c,{label:"app-c"}]]')"

# DB 위젯 — 배포 방식에 따라 차원 키가 다르다
if [ "${DB_MODE_USED:-$DB_MODE}" = "rds" ] && [ -n "${DB_IDENTIFIER:-}" ]; then
  DB_TITLE="RDS ${DB_IDENTIFIER}"
  DB_M="$(jq -nc --arg d "$DB_IDENTIFIER" \
    '[["AWS/RDS","CPUUtilization","DBInstanceIdentifier",$d],
      ["AWS/RDS","DatabaseConnections","DBInstanceIdentifier",$d],
      ["AWS/RDS","FreeStorageSpace","DBInstanceIdentifier",$d]]')"
elif [ -n "${AURORA_CLUSTER:-}" ]; then
  DB_TITLE="Aurora ${AURORA_CLUSTER}"
  DB_M="$(jq -nc --arg d "$AURORA_CLUSTER" \
    '[["AWS/RDS","CPUUtilization","DBClusterIdentifier",$d],
      ["AWS/RDS","DatabaseConnections","DBClusterIdentifier",$d]]')"
else
  DB_TITLE="RDS (식별자 미확인)"
  DB_M='[["AWS/RDS","CPUUtilization"]]'
fi

# Logs Insights 쿼리 — jq --arg 로 넘기면 이스케이프를 jq가 처리한다.
Q_NGINX='fields @timestamp, @message
| filter @logStream like /nginx/
| parse @message "* * * [*] \"* * *\" * *" as ip, ident, user, ts, method, path, proto, status, bytes
| stats count(*) as c by status
| sort c desc'
Q_FLOW='fields @timestamp, srcAddr, dstAddr, dstPort, action
| filter action="REJECT"
| stats count(*) as c by srcAddr, dstPort
| sort c desc
| limit 20'

DASH="$(jq -nc \
  --arg region "$REGION" \
  --argjson ec2 "$EC2_M" --argjson mem "$MEM_M" --argjson db "$DB_M" \
  --arg dbTitle "$DB_TITLE" \
  --arg lgApp "$N_LOGGROUP_APP" --arg lgFlow "$N_LOGGROUP_FLOW" \
  --arg qNginx "$Q_NGINX" --arg qFlow "$Q_FLOW" \
  '{widgets:[
    {type:"metric",x:0,y:0,width:12,height:6,
     properties:{region:$region,title:"3계층 EC2 CPU",stat:"Average",period:300,metrics:$ec2}},
    {type:"metric",x:12,y:0,width:12,height:6,
     properties:{region:$region,title:$dbTitle,stat:"Average",period:300,metrics:$db}},
    {type:"metric",x:0,y:6,width:12,height:6,
     properties:{region:$region,title:"메모리 사용률 (CloudWatch Agent)",stat:"Average",period:300,metrics:$mem}},
    {type:"log",x:12,y:6,width:12,height:6,
     properties:{region:$region,title:"nginx 접근 로그 — 상태 코드별",
                 query:("SOURCE \u0027" + $lgApp + "\u0027 | " + $qNginx)}},
    {type:"log",x:0,y:12,width:24,height:6,
     properties:{region:$region,title:"VPC Flow Logs — REJECT 상위",
                 query:("SOURCE \u0027" + $lgFlow + "\u0027 | " + $qFlow)}}]}')"

# 보내기 전에 유효성을 확인한다. 깨진 JSON을 API에 던지지 않는다.
if printf '%s' "$DASH" | jq -e . >/dev/null 2>&1; then
  aws cloudwatch put-dashboard --dashboard-name "$N_DASHBOARD" --dashboard-body "$DASH" >/dev/null \
    && ok "대시보드 생성: $N_DASHBOARD" \
    || { warn "대시보드 생성 실패"; printf '%s' "$DASH" | head -c 400 >&2; echo >&2; }
else
  err "대시보드 JSON 생성 실패 — 전송하지 않습니다"
fi
save_state DASHBOARD "$N_DASHBOARD"

save_state LAB09_DONE 1
ok "Lab 9 완료"
