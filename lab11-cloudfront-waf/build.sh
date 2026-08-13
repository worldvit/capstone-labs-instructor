#!/usr/bin/env bash
# Lab 11 — CloudFront + S3 + WAF
#
# Lab 10까지의 구성은 모든 요청이 ALB와 Tomcat까지 도달했다.
# 여기서 정적·동적을 분리해 오리진 부하를 줄이고 엣지에서 방어한다.
#
#   인터넷 → CloudFront ─┬─ /static/*  → S3 (OAC, 캐시 있음)
#                        └─ 그 외      → ALB → Tomcat (캐시 없음)
#                         ↑ WAF (us-east-1, CLOUDFRONT 범위)
#
# WAF Web ACL 은 CloudFront 범위일 때 반드시 us-east-1 에 만들어야 한다.
source "$(dirname "$0")/../00-common/bootstrap.sh"
guard
banner "Lab 11 build — CloudFront + S3 + WAF"
LAB=11
need_state ALB_DNS BUCKET_WEB VPCE_S3

WAF_REGION="us-east-1"     # CLOUDFRONT 범위 WAF 의 고정 리전

# ---------- 1. WAF Web ACL ----------
WAF_ARN="$(_q aws wafv2 list-web-acls --scope CLOUDFRONT --region "$WAF_REGION" \
  --query "WebACLs[?Name=='$N_WAF'].ARN | [0]" --output text)"
WAF_ID="$(_q aws wafv2 list-web-acls --scope CLOUDFRONT --region "$WAF_REGION" \
  --query "WebACLs[?Name=='$N_WAF'].Id | [0]" --output text)"

if [ -z "$WAF_ARN" ]; then
  # 규칙 정의는 jq 로 만든다. heredoc 으로 JSON 을 짜면 이스케이프가 어긋난다.
  RULES="$(jq -nc --argjson limit "${WAF_RATE_LIMIT:-1000}" '[
    {Name:"AWSManagedCommon",Priority:1,OverrideAction:{None:{}},
     Statement:{ManagedRuleGroupStatement:{VendorName:"AWS",Name:"AWSManagedRulesCommonRuleSet"}},
     VisibilityConfig:{SampledRequestsEnabled:true,CloudWatchMetricsEnabled:true,MetricName:"common"}},
    {Name:"AWSManagedBadInputs",Priority:2,OverrideAction:{None:{}},
     Statement:{ManagedRuleGroupStatement:{VendorName:"AWS",Name:"AWSManagedRulesKnownBadInputsRuleSet"}},
     VisibilityConfig:{SampledRequestsEnabled:true,CloudWatchMetricsEnabled:true,MetricName:"badinputs"}},
    {Name:"RateLimit",Priority:3,Action:{Block:{}},
     Statement:{RateBasedStatement:{Limit:$limit,AggregateKeyType:"IP"}},
     VisibilityConfig:{SampledRequestsEnabled:true,CloudWatchMetricsEnabled:true,MetricName:"ratelimit"}}]')"
  printf '%s' "$RULES" | jq -e . >/dev/null || die "WAF 규칙 JSON 생성 실패"

  RES="$(aws wafv2 create-web-acl --name "$N_WAF" --scope CLOUDFRONT --region "$WAF_REGION" \
        --default-action Allow={} --rules "$RULES" \
        --visibility-config "SampledRequestsEnabled=true,CloudWatchMetricsEnabled=true,MetricName=${PREFIX}waf" \
        --tags Key=Project,Value=capstone Key=Lab,Value=$LAB Key=Owner,Value="$PREFIX" \
        --output json 2>&1)" || { err "WAF 생성 실패"; printf '      %s\n' "$RES" >&2; exit 1; }
  WAF_ARN="$(printf '%s' "$RES" | jq -r '.Summary.ARN')"
  WAF_ID="$(printf '%s' "$RES" | jq -r '.Summary.Id')"
  ok "WAF Web ACL 생성: $N_WAF (us-east-1 / CLOUDFRONT 범위)"
  log "  규칙: 관리형 Common, 관리형 KnownBadInputs, 속도 기반 ${WAF_RATE_LIMIT:-1000}/5분"
else
  skip "WAF Web ACL ($N_WAF)"
fi
save_state WAF_ARN "$WAF_ARN"
save_state WAF_ID "$WAF_ID"

# ---------- 2. Origin Access Control ----------
OAC_ID="$(_q aws cloudfront list-origin-access-controls \
  --query "OriginAccessControlList.Items[?Name=='$N_OAC'].Id | [0]" --output text)"
if [ -z "$OAC_ID" ]; then
  OAC_ID="$(aws cloudfront create-origin-access-control --origin-access-control-config \
    "Name=$N_OAC,Description=capstone OAC,SigningProtocol=sigv4,SigningBehavior=always,OriginAccessControlOriginType=s3" \
    --query 'OriginAccessControl.Id' --output text)"
  ok "OAC 생성: $OAC_ID"
else
  skip "OAC ($OAC_ID)"
fi
save_state OAC_ID "$OAC_ID"

# ---------- 3. 관리형 정책 ID 조회 ----------
# ID 를 하드코딩하면 정책이 바뀌었을 때 조용히 어긋난다. 이름으로 찾는다.
# 응답 구조가 바뀌어도 견디도록 jq 로 훑는다. JMESPath 경로를 고정하면 조용히 깨진다.
managed_policy_id() { # <타입 cache|origin-request> <이름>
  local json
  case "$1" in
    cache)          json="$(aws cloudfront list-cache-policies --type managed --output json 2>/dev/null)" ;;
    origin-request) json="$(aws cloudfront list-origin-request-policies --type managed --output json 2>/dev/null)" ;;
    *) return 1 ;;
  esac
  [ -n "$json" ] || return 1
  # Id 와 (하위 어딘가의) Name 을 동시에 가진 객체를 찾는다.
  # 응답 깊이가 바뀌어도 견딘다.
  printf '%s' "$json" | jq -r --arg n "$2" '
    [ .. | objects
      | select(has("Id"))
      | select([ .. | objects | .Name? // empty ] | index($n))
      | .Id ] | first // empty' 2>/dev/null
}

# 관리형 정책의 실제 이름은 "Managed-" 접두사가 붙는다(예: Managed-CachingOptimized).
# 접두사 유무를 모두 시도한다.
find_policy() { # <타입> <이름>
  local id
  id="$(managed_policy_id "$1" "Managed-$2")"
  [ -n "$id" ] || id="$(managed_policy_id "$1" "$2")"
  printf '%s' "$id"
}
CP_OPTIMIZED="$(find_policy cache CachingOptimized)"
CP_DISABLED="$(find_policy cache CachingDisabled)"
ORP_ALLVIEWER="$(find_policy origin-request AllViewer)"

if [ -z "$CP_OPTIMIZED" ] || [ -z "$CP_DISABLED" ] || [ -z "$ORP_ALLVIEWER" ]; then
  warn "이름으로 관리형 정책을 찾지 못했습니다. 사용 가능한 정책:"
  aws cloudfront list-cache-policies --type managed --output json 2>/dev/null \
    | jq -r '.CachePolicyList.Items[]? | "    cache  \(.CachePolicy.Id)  \(.CachePolicy.CachePolicyConfig.Name)"' 2>/dev/null | head -12 >&2
  aws cloudfront list-origin-request-policies --type managed --output json 2>/dev/null \
    | jq -r '.OriginRequestPolicyList.Items[]? | "    origin \(.OriginRequestPolicy.Id)  \(.OriginRequestPolicy.OriginRequestPolicyConfig.Name)"' 2>/dev/null | head -12 >&2
  # AWS 가 공표한 고정 ID 로 대체한다(관리형 정책의 ID 는 모든 계정에서 동일하다).
  : "${CP_OPTIMIZED:=658327ea-f89d-4fab-a63d-7e88639e58f6}"
  : "${CP_DISABLED:=4135ea2d-6df8-44a3-9df3-4b5a84be39ad}"
  : "${ORP_ALLVIEWER:=216adef6-5c7f-47e4-b989-5492eafa07d3}"
  warn "공표된 고정 ID 로 진행합니다."
fi
ok "관리형 정책 확정"
log "  CachingOptimized=$CP_OPTIMIZED"
log "  CachingDisabled=$CP_DISABLED"
log "  AllViewer=$ORP_ALLVIEWER"

# ---------- 4. CloudFront 배포 ----------
DIST_ID="$(_q aws cloudfront list-distributions \
  --query "DistributionList.Items[?Comment=='${PREFIX}-cdn'].Id | [0]" --output text)"

if [ -z "$DIST_ID" ]; then
  S3_DOMAIN="${BUCKET_WEB}.s3.${REGION}.amazonaws.com"
  DIST_CFG="$(jq -nc \
    --arg ref "${PREFIX}-$(date +%s)" --arg comment "${PREFIX}-cdn" \
    --arg alb "$ALB_DNS" --arg s3 "$S3_DOMAIN" --arg oac "$OAC_ID" \
    --arg waf "$WAF_ARN" --arg cpOpt "$CP_OPTIMIZED" --arg cpOff "$CP_DISABLED" \
    --arg orp "$ORP_ALLVIEWER" \
    '{CallerReference:$ref, Comment:$comment, Enabled:true,
      Origins:{Quantity:2, Items:[
        {Id:"alb-origin", DomainName:$alb,
         CustomOriginConfig:{HTTPPort:80, HTTPSPort:443, OriginProtocolPolicy:"http-only",
                             OriginSslProtocols:{Quantity:1, Items:["TLSv1.2"]},
                             OriginReadTimeout:30, OriginKeepaliveTimeout:5}},
        {Id:"s3-origin", DomainName:$s3, OriginAccessControlId:$oac,
         S3OriginConfig:{OriginAccessIdentity:""}}]},
      DefaultCacheBehavior:{
        TargetOriginId:"alb-origin", ViewerProtocolPolicy:"redirect-to-https",
        AllowedMethods:{Quantity:7, Items:["GET","HEAD","OPTIONS","PUT","POST","PATCH","DELETE"],
                        CachedMethods:{Quantity:2, Items:["GET","HEAD"]}},
        CachePolicyId:$cpOff, OriginRequestPolicyId:$orp, Compress:true},
      CacheBehaviors:{Quantity:1, Items:[
        {PathPattern:"/static/*", TargetOriginId:"s3-origin",
         ViewerProtocolPolicy:"redirect-to-https",
         AllowedMethods:{Quantity:2, Items:["GET","HEAD"],
                         CachedMethods:{Quantity:2, Items:["GET","HEAD"]}},
         CachePolicyId:$cpOpt, Compress:true}]},
      WebACLId:$waf, PriceClass:"PriceClass_200", DefaultRootObject:""}')"
  printf '%s' "$DIST_CFG" | jq -e . >/dev/null || die "배포 설정 JSON 생성 실패"

  RES="$(aws cloudfront create-distribution --distribution-config "$DIST_CFG" --output json 2>&1)" \
    || { err "CloudFront 배포 생성 실패"; printf '      %s\n' "$RES" | head -20 >&2; exit 1; }
  DIST_ID="$(printf '%s' "$RES" | jq -r '.Distribution.Id')"
  ok "CloudFront 배포 생성: $DIST_ID"
  aws cloudfront tag-resource --resource "arn:aws:cloudfront::${ACCOUNT_ID}:distribution/${DIST_ID}" \
    --tags "Items=[{Key=Project,Value=capstone},{Key=Lab,Value=$LAB},{Key=Owner,Value=$PREFIX}]" >/dev/null 2>&1 || true
else
  skip "CloudFront 배포 ($DIST_ID)"
fi
save_state CLOUDFRONT_ID "$DIST_ID"

CF_DOMAIN="$(_q aws cloudfront get-distribution --id "$DIST_ID" --query 'Distribution.DomainName' --output text)"
save_state CLOUDFRONT_DOMAIN "$CF_DOMAIN"
ok "배포 도메인: $CF_DOMAIN"

# ---------- 5. S3 버킷 정책에 OAC 허용 추가 ----------
# Lab 6 에서 건 SourceVpce 조건을 유지한 채 CloudFront 경로를 추가한다.
#   App 서버 → 게이트웨이 엔드포인트 경유 (내부 접근)
#   인터넷   → CloudFront OAC 경유 (공개 배포)
POLICY="$(jq -nc \
  --arg b "$BUCKET_WEB" --arg vpce "$VPCE_S3" \
  --arg dist "arn:aws:cloudfront::${ACCOUNT_ID}:distribution/${DIST_ID}" \
  '{Version:"2012-10-17", Statement:[
     {Sid:"AllowVpcEndpointOnly", Effect:"Allow", Principal:"*",
      Action:["s3:GetObject","s3:ListBucket"],
      Resource:["arn:aws:s3:::\($b)","arn:aws:s3:::\($b)/*"],
      Condition:{StringEquals:{"aws:SourceVpce":$vpce}}},
     {Sid:"AllowCloudFrontOAC", Effect:"Allow",
      Principal:{Service:"cloudfront.amazonaws.com"},
      Action:"s3:GetObject", Resource:"arn:aws:s3:::\($b)/*",
      Condition:{StringEquals:{"AWS:SourceArn":$dist}}},
     {Sid:"DenyInsecureTransport", Effect:"Deny", Principal:"*", Action:"s3:*",
      Resource:["arn:aws:s3:::\($b)","arn:aws:s3:::\($b)/*"],
      Condition:{Bool:{"aws:SecureTransport":"false"}}}]}')"
printf '%s' "$POLICY" | jq -e . >/dev/null || die "버킷 정책 JSON 생성 실패"
aws s3api put-bucket-policy --bucket "$BUCKET_WEB" --policy "$POLICY" >/dev/null \
  && ok "S3 버킷 정책 갱신 (엔드포인트 + OAC 두 경로 허용)" \
  || die "버킷 정책 적용 실패"

# ---------- 6. 정적 콘텐츠 보강 ----------
# 캐시 동작을 눈으로 보려면 크기가 있는 파일이 필요하다.
TMP="$(mktemp -d)"
cat > "$TMP/index.html" << 'HTML'
<!doctype html><meta charset="utf-8"><title>capstone static</title>
<link rel="stylesheet" href="style.css">
<h1>정적 콘텐츠 — S3 오리진</h1>
<p>이 페이지는 CloudFront 엣지에 캐시됩니다. 응답 헤더의 X-Cache 를 확인하십시오.</p>
<p>동적 페이지는 <a href="/">여기</a>(ALB → Tomcat)입니다.</p>
HTML
printf 'body{font-family:sans-serif;margin:3rem;line-height:1.7}h1{color:#0b6}\n' > "$TMP/style.css"
head -c 200000 /dev/urandom | base64 > "$TMP/large.txt"   # 캐시 효과 관찰용
aws s3 cp "$TMP/index.html" "s3://$BUCKET_WEB/static/index.html" --content-type text/html >/dev/null
aws s3 cp "$TMP/style.css"  "s3://$BUCKET_WEB/static/style.css"  --content-type text/css  >/dev/null
aws s3 cp "$TMP/large.txt"  "s3://$BUCKET_WEB/static/large.txt"  --content-type text/plain >/dev/null
rm -rf "$TMP"
ok "정적 콘텐츠 업로드 (index.html, style.css, large.txt)"

# ---------- 7. ALB 를 CloudFront 경유로 제한 ----------
PL="$(_q aws ec2 describe-managed-prefix-lists \
  --filters "Name=prefix-list-name,Values=com.amazonaws.global.cloudfront.origin-facing" \
  --query 'PrefixLists[0].PrefixListId' --output text)"
if [ -n "$PL" ] && [ -n "${SG_ALB:-}" ]; then
  e="$(aws ec2 authorize-security-group-ingress --group-id "$SG_ALB" \
       --ip-permissions "IpProtocol=tcp,FromPort=80,ToPort=80,PrefixListIds=[{PrefixListId=$PL}]" 2>&1 >/dev/null)" \
    && ok "ALB SG에 CloudFront 프리픽스 목록 허용 ($PL)" \
    || case "$e" in
         *Duplicate*) skip "프리픽스 목록 규칙" ;;
         *) warn "프리픽스 목록 규칙 추가 실패"; printf '      %s\n' "$e" >&2 ;;
       esac
  save_state CF_PREFIX_LIST "$PL"

  if [ "${LOCK_ALB:-0}" = "1" ]; then
    aws ec2 revoke-security-group-ingress --group-id "$SG_ALB" \
      --ip-permissions "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0}]" >/dev/null 2>&1 \
      && { ok "ALB의 0.0.0.0/0:80 제거 — CloudFront 경유만 허용"; save_state ALB_LOCKED 1; } \
      || warn "0.0.0.0/0 규칙 제거 실패(이미 없을 수 있음)"
  else
    log "LOCK_ALB=1 로 실행하면 ALB 직접 접근을 막고 CloudFront 경유만 허용합니다."
  fi
else
  warn "CloudFront 프리픽스 목록을 찾지 못했습니다"
fi

# ---------- 8. 배포 완료 대기 ----------
log "배포 Deployed 대기 (5~15분 — 엣지 전파에 시간이 걸립니다)"
aws cloudfront wait distribution-deployed --id "$DIST_ID" 2>/dev/null \
  || warn "대기 시간 초과. 콘솔에서 상태를 확인하십시오."

save_state LAB11_DONE 1

banner "구성 완료"
cat << GUIDE
  CloudFront:  https://${CF_DOMAIN}/
  ALB(직접):   http://${ALB_DNS}/

  확인할 것
    1) 동적 경로 — ALB → Tomcat 으로 흐르는가
         curl -s https://${CF_DOMAIN}/ | grep -E 'APP_INSTANCE|DB_STATUS'

    2) 정적 경로 — S3 오리진, 캐시 동작
         curl -sI https://${CF_DOMAIN}/static/index.html | grep -i 'x-cache'
       처음엔 Miss, 두 번째부터 Hit from cloudfront 가 나와야 합니다.

    3) 캐시 효과 — 같은 파일을 두 번 받아 시간을 비교
         time curl -s -o /dev/null https://${CF_DOMAIN}/static/large.txt
         time curl -s -o /dev/null https://${CF_DOMAIN}/static/large.txt

    4) 동적 경로는 캐시되지 않는다
         curl -sI https://${CF_DOMAIN}/ | grep -i 'x-cache'
       Miss 가 계속 나옵니다. CachingDisabled 정책 때문입니다.

    5) WAF 차단 — 알려진 공격 패턴을 보내면 403
         curl -s -o /dev/null -w '%{http_code}\\n' "https://${CF_DOMAIN}/?q=<script>alert(1)</script>"

    6) HTTPS 강제
         curl -s -o /dev/null -w '%{http_code} %{redirect_url}\\n' http://${CF_DOMAIN}/
GUIDE
ok "Lab 11 완료"
