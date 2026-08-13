#!/usr/bin/env bash
# Lab 6 — S3 정적 웹 버킷 + 로그 버킷 + 엔드포인트 경유 접근 제한
source "$(dirname "$0")/../00-common/bootstrap.sh"
guard
banner "Lab 6 build — S3 정적 웹 + 엔드포인트 경유 접근"
LAB=6
need_state VPCE_S3

export BUCKET_WEB="${PREFIX}-web-${ACCOUNT_ID}"
export BUCKET_LOGS="${PREFIX}-logs-${ACCOUNT_ID}"

mk_bucket() { # 이름
  local b="$1"
  if aws s3api head-bucket --bucket "$b" >/dev/null 2>&1; then skip "버킷 $b"; return; fi
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$b" >/dev/null           # us-east-1은 LocationConstraint 생략
  else
    aws s3api create-bucket --bucket "$b" \
      --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null
  fi
  ok "버킷 생성: $b"
  aws s3api put-public-access-block --bucket "$b" --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" >/dev/null
  aws s3api put-bucket-encryption --bucket "$b" --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}' >/dev/null
  aws s3api put-bucket-versioning --bucket "$b" --versioning-configuration Status=Enabled >/dev/null
  aws s3api put-bucket-tagging --bucket "$b" --tagging \
    "TagSet=[{Key=Project,Value=capstone},{Key=Lab,Value=$LAB},{Key=Owner,Value=$PREFIX}]" >/dev/null
}
mk_bucket "$BUCKET_WEB"
mk_bucket "$BUCKET_LOGS"
save_state BUCKET_WEB "$BUCKET_WEB"
save_state BUCKET_LOGS "$BUCKET_LOGS"

# ---------- 정적 콘텐츠 ----------
TMP="$(mktemp -d)"
cat > "$TMP/index.html" << 'HTML'
<!doctype html><meta charset="utf-8"><title>capstone static</title>
<h1>Capstone Static Site</h1><p>S3 origin via CloudFront OAC</p>
HTML
printf 'body{font-family:sans-serif;margin:3rem}\n' > "$TMP/style.css"
aws s3 cp "$TMP/index.html" "s3://$BUCKET_WEB/static/index.html" --content-type text/html >/dev/null
aws s3 cp "$TMP/style.css"  "s3://$BUCKET_WEB/static/style.css"  --content-type text/css  >/dev/null
rm -rf "$TMP"
ok "정적 콘텐츠 업로드 (static/index.html, static/style.css)"

# ---------- 로그 버킷 수명 주기 ----------
aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET_LOGS" --lifecycle-configuration '{
 "Rules":[{"ID":"logs-tiering","Status":"Enabled","Filter":{"Prefix":""},
  "Transitions":[{"Days":30,"StorageClass":"STANDARD_IA"},{"Days":90,"StorageClass":"GLACIER_IR"}],
  "Expiration":{"Days":365},
  "NoncurrentVersionExpiration":{"NoncurrentDays":30}}]}' >/dev/null
ok "로그 버킷 수명 주기 규칙 적용 (30d IA / 90d Glacier IR / 365d 만료)"

# ---------- 엔드포인트 경유 접근만 허용 ----------
cat > /tmp/${PREFIX}-web-policy.json << JSON
{"Version":"2012-10-17","Statement":[
 {"Sid":"AllowVpcEndpointOnly","Effect":"Allow","Principal":"*",
  "Action":["s3:GetObject","s3:ListBucket"],
  "Resource":["arn:aws:s3:::${BUCKET_WEB}","arn:aws:s3:::${BUCKET_WEB}/*"],
  "Condition":{"StringEquals":{"aws:SourceVpce":"${VPCE_S3}"}}},
 {"Sid":"DenyInsecureTransport","Effect":"Deny","Principal":"*","Action":"s3:*",
  "Resource":["arn:aws:s3:::${BUCKET_WEB}","arn:aws:s3:::${BUCKET_WEB}/*"],
  "Condition":{"Bool":{"aws:SecureTransport":"false"}}}]}
JSON
aws s3api put-bucket-policy --bucket "$BUCKET_WEB" --policy file:///tmp/${PREFIX}-web-policy.json >/dev/null
ok "버킷 정책 적용: aws:SourceVpce=$VPCE_S3 조건"
warn "이 시점부터 콘솔/로컬에서의 GetObject는 거부됩니다. Lab 11에서 OAC 조건을 추가로 허용합니다."

save_state LAB06_DONE 1
ok "Lab 6 완료"
