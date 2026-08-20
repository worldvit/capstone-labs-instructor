#!/usr/bin/env bash
# ============================================================
# teardown-all-end.sh — teardown-all.sh 뒤에 실행하는 마무리 점검
#
#   bash teardown-all-end.sh            # 확인만 (아무것도 지우지 않음)
#   bash teardown-all-end.sh --clean    # 잔여 리소스까지 삭제
#
# 왜 따로 있는가:
#   랩별 teardown.sh 는 build.sh 가 만든 것을 되돌린다.
#   그런데 콘솔로 실습하면 스크립트가 모르는 것이 남는다.
#     · S3 이벤트 알림      (실습 12에서 콘솔로 설정)
#     · CloudFront 오리진   (실습 11·12에서 손으로 추가)
#     · WAF 보호 팩         us-east-1 이라 서울만 보면 놓친다
#     · 버전 있는 S3 객체   버전을 지워야 버킷이 지워진다
#
#   또 "정말 다 지워졌는가"를 돈 나가는 순서로 확인해 준다.
# ============================================================
set -uo pipefail
cd "$(dirname "$0")"
source 00-common/bootstrap.sh
set +e   # 조회 실패는 정상 흐름이다

CLEAN=0
[ "${1:-}" = "--clean" ] && CLEAN=1

export AWS_PAGER=""
R="${REGION:-ap-northeast-2}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
LEFT=0

q() { aws --region "$R" "$@" 2>/dev/null | tr -d '\r'; }

# 항목 하나를 세고, --clean 이면 지운다.
# report <이름> <개수> <삭제명령...>
report() {
  local name="$1" n="$2"; shift 2
  n="${n:-0}"; [ "$n" = "None" ] && n=0
  if [ "$n" -eq 0 ] 2>/dev/null; then
    printf '  \033[32m없음\033[0m  %s\n' "$name"
    return 0
  fi
  printf '  \033[31m남음\033[0m  %-24s %s개\n' "$name" "$n"
  LEFT=$((LEFT+n))
  if [ "$CLEAN" = "1" ] && [ $# -gt 0 ]; then
    "$@" >/dev/null 2>&1 && printf '        \033[33m→ 삭제 요청함\033[0m\n'
  fi
}

banner "잔여 리소스 점검  (접두사 ${PREFIX:-cap})"
[ "$CLEAN" = "1" ] && warn "--clean : 발견된 잔여 리소스를 삭제합니다." \
                   || log  "확인만 합니다. 삭제하려면 --clean 을 붙이십시오."

# ------------------------------------------------------------
# 1. 스크립트가 모르는 것 — 콘솔로 만든 잔재
# ------------------------------------------------------------
banner "1. 콘솔로 만든 잔재"

# --- S3 이벤트 알림 ---
BW="$(q s3api list-buckets --query "Buckets[?starts_with(Name,'${PREFIX:-cap}-web-')].Name | [0]" --output text)"
if [ -n "$BW" ] && [ "$BW" != "None" ]; then
  n="$(q s3api get-bucket-notification-configuration --bucket "$BW" \
        --query 'length(TopicConfigurations)' --output text)"
  report "S3 이벤트 알림" "$n" \
    aws s3api put-bucket-notification-configuration --region "$R" \
      --bucket "$BW" --notification-configuration '{}'
else
  printf '  \033[32m없음\033[0m  S3 이벤트 알림 (웹 버킷 없음)\n'
fi

# --- CloudFront 배포 ---
CFID="$(aws cloudfront list-distributions \
        --query "DistributionList.Items[?Comment=='${PREFIX:-cap}-cdn'].Id | [0]" \
        --output text 2>/dev/null)"
if [ -n "$CFID" ] && [ "$CFID" != "None" ]; then
  ST="$(aws cloudfront get-distribution --id "$CFID" --query 'Distribution.Status' --output text 2>/dev/null)"
  EN="$(aws cloudfront get-distribution --id "$CFID" \
        --query 'Distribution.DistributionConfig.Enabled' --output text 2>/dev/null)"
  printf '  \033[31m남음\033[0m  %-24s %s (%s / Enabled=%s)\n' "CloudFront 배포" "$CFID" "$ST" "$EN"
  LEFT=$((LEFT+1))
  warn "  CloudFront 는 비활성화 후에야 삭제됩니다. 콘솔에서 진행하십시오."
  log  "  1) 배포 선택 → 비활성화  2) 상태가 Deployed 가 될 때까지 15~20분  3) 삭제"
else
  printf '  \033[32m없음\033[0m  CloudFront 배포\n'
fi

# --- WAF (us-east-1) ---
WAFID="$(aws wafv2 list-web-acls --scope CLOUDFRONT --region us-east-1 \
         --query "WebACLs[?Name=='${PREFIX:-cap}-waf'].Id | [0]" --output text 2>/dev/null)"
if [ -n "$WAFID" ] && [ "$WAFID" != "None" ]; then
  printf '  \033[31m남음\033[0m  %-24s %s\n' "WAF 보호 팩(us-east-1)" "${PREFIX:-cap}-waf"
  LEFT=$((LEFT+1))
  err "  WAF 는 월 단위로 과금됩니다. 반드시 지우십시오."
  if [ "$CLEAN" = "1" ]; then
    LT="$(aws wafv2 get-web-acl --scope CLOUDFRONT --region us-east-1 \
          --name "${PREFIX:-cap}-waf" --id "$WAFID" --query LockToken --output text 2>/dev/null)"
    aws wafv2 delete-web-acl --scope CLOUDFRONT --region us-east-1 \
      --name "${PREFIX:-cap}-waf" --id "$WAFID" --lock-token "$LT" >/dev/null 2>&1 \
      && printf '        \033[33m→ 삭제 요청함\033[0m\n' \
      || warn "  삭제 실패 — 배포에 연결된 상태이면 배포를 먼저 지우십시오."
  fi
else
  printf '  \033[32m없음\033[0m  WAF 보호 팩(us-east-1)\n'
fi

# ------------------------------------------------------------
# 2. 돈 나가는 것 — 비싼 순서로
# ------------------------------------------------------------
banner "2. 과금되는 리소스"

report "NAT 게이트웨이" \
  "$(q ec2 describe-nat-gateways --filter Name=state,Values=available \
      --query 'length(NatGateways)' --output text)"

report "RDS 인스턴스" \
  "$(q rds describe-db-instances --query 'length(DBInstances)' --output text)"

report "ALB" \
  "$(q elbv2 describe-load-balancers --query 'length(LoadBalancers)' --output text)"

report "EC2 실행 중" \
  "$(q ec2 describe-instances --filters Name=instance-state-name,Values=running \
      --query 'length(Reservations[].Instances[])' --output text)"

report "EFS 파일 시스템" \
  "$(q efs describe-file-systems --query 'length(FileSystems)' --output text)"

report "Transit Gateway" \
  "$(q ec2 describe-transit-gateways --filters Name=state,Values=available \
      --query 'length(TransitGateways)' --output text)"

report "인터페이스 엔드포인트" \
  "$(q ec2 describe-vpc-endpoints \
      --query "length(VpcEndpoints[?VpcEndpointType=='Interface'])" --output text)"

report "탄력적 IP" \
  "$(q ec2 describe-addresses --query 'length(Addresses)' --output text)"

# ------------------------------------------------------------
# 3. 과금은 적지만 이름을 차지하는 것
# ------------------------------------------------------------
banner "3. 이름을 차지하는 리소스"

report "VPC" \
  "$(q ec2 describe-vpcs --filters "Name=tag:Owner,Values=${PREFIX:-cap}" \
      --query 'length(Vpcs)' --output text)"

report "IAM 역할" \
  "$(aws iam list-roles --query "length(Roles[?starts_with(RoleName,'${PREFIX:-cap}-')])" \
      --output text 2>/dev/null)"

report "SQS 대기열" \
  "$(q sqs list-queues --queue-name-prefix "${PREFIX:-cap}-" \
      --query 'length(QueueUrls)' --output text)"

report "SNS 주제" \
  "$(aws sns list-topics --region "$R" \
      --query "length(Topics[?contains(TopicArn,'${PREFIX:-cap}-')])" --output text 2>/dev/null)"

report "Lambda 함수" \
  "$(q lambda list-functions \
      --query "length(Functions[?starts_with(FunctionName,'${PREFIX:-cap}-')])" --output text)"

report "API Gateway" \
  "$(q apigatewayv2 get-apis \
      --query "length(Items[?starts_with(Name,'${PREFIX:-cap}-')])" --output text)"

report "백업 볼트" \
  "$(q backup list-backup-vaults \
      --query "length(BackupVaultList[?starts_with(BackupVaultName,'${PREFIX:-cap}-')])" --output text)"

# ------------------------------------------------------------
# 4. S3 버킷 — 버전까지 지워야 사라진다
# ------------------------------------------------------------
banner "4. S3 버킷"

BUCKETS="$(aws s3api list-buckets \
           --query "Buckets[?starts_with(Name,'${PREFIX:-cap}-')].Name" --output text 2>/dev/null)"
if [ -z "$BUCKETS" ]; then
  printf '  \033[32m없음\033[0m  S3 버킷\n'
else
  for b in $BUCKETS; do
    printf '  \033[31m남음\033[0m  %s\n' "$b"
    LEFT=$((LEFT+1))
    if [ "$CLEAN" = "1" ]; then
      log "        버전 포함 비우는 중..."
      # 버전 관리를 켠 버킷은 현재 객체만 지워서는 비워지지 않는다.
      aws s3api list-object-versions --bucket "$b" --output json 2>/dev/null \
      | jq -r '(.Versions // []), (.DeleteMarkers // []) | .[]
               | "\(.Key)\t\(.VersionId)"' 2>/dev/null \
      | while IFS=$'\t' read -r k v; do
          [ -n "$k" ] && aws s3api delete-object --bucket "$b" --key "$k" --version-id "$v" >/dev/null 2>&1
        done
      aws s3 rb "s3://$b" --force >/dev/null 2>&1 \
        && printf '        \033[33m→ 삭제함\033[0m\n' \
        || warn "        삭제 실패 — 남은 객체를 확인하십시오."
    fi
  done
  [ "$CLEAN" = "0" ] && log "  버전 관리를 켠 버킷은 --clean 으로 버전까지 지워야 사라집니다."
fi

# ------------------------------------------------------------
# 마무리
# ------------------------------------------------------------
banner "결과"
if [ "$LEFT" -eq 0 ]; then
  ok "잔여 리소스 없음 — 정리가 끝났습니다."
else
  if [ "$CLEAN" = "1" ]; then
    warn "삭제를 요청했습니다. 몇 분 뒤 다시 실행해 확인하십시오."
    log  "  bash teardown-all-end.sh"
  else
    warn "잔여 항목 ${LEFT}건 — 삭제하려면 아래를 실행하십시오."
    log  "  bash teardown-all-end.sh --clean"
  fi
fi

log ""
log "태그로 남은 것을 한 번에 보려면:"
log "  aws resourcegroupstaggingapi get-resources --region $R \\"
log "    --tag-filters Key=Owner,Values=${PREFIX:-cap} \\"
log "    --query 'ResourceTagMappingList[].ResourceARN' --output text"
