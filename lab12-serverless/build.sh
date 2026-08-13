#!/usr/bin/env bash
# Lab 12 — SNS + SQS(+DLQ) + Lambda + API Gateway
source "$(dirname "$0")/../00-common/bootstrap.sh"
guard
banner "Lab 12 build — 서버리스 이벤트 계층"
LAB=12
need_state BUCKET_WEB

# ---------- 1. SQS DLQ / 메인 큐 ----------
mk_queue() { # 이름 속성JSON 키
  local n="$1" attrs="$2" key="$3" url
  url="$(_q aws sqs get-queue-url --queue-name "$n" --query QueueUrl --output text)"
  if [ -z "$url" ]; then
    url="$(aws sqs create-queue --queue-name "$n" ${attrs:+--attributes "$attrs"} \
      --tags Project=capstone,Lab=$LAB,Owner="$PREFIX" --query QueueUrl --output text)"
    ok "SQS 생성: $n"
  else skip "SQS $n"; fi
  save_state "$key" "$url"
}
mk_queue "$N_SQS_DLQ" "" SQS_DLQ_URL
DLQ_ARN="$(_q aws sqs get-queue-attributes --queue-url "$SQS_DLQ_URL" --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)"
save_state SQS_DLQ_ARN "$DLQ_ARN"

mk_queue "$N_SQS" "$(jq -nc --arg d "$DLQ_ARN" '{VisibilityTimeout:"60",RedrivePolicy:({deadLetterTargetArn:$d,maxReceiveCount:3}|tostring)}')" SQS_URL
SQS_ARN="$(_q aws sqs get-queue-attributes --queue-url "$SQS_URL" --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)"
save_state SQS_ARN "$SQS_ARN"
ok "DLQ 연결 완료 (maxReceiveCount=3)"

# ---------- 2. SNS → SQS 팬아웃 ----------
SNS_EV="$(_q aws sns create-topic --name "$N_SNS_EVENTS" \
  --tags Key=Project,Value=capstone Key=Lab,Value=$LAB Key=Owner,Value="$PREFIX" --query TopicArn --output text)"
save_state SNS_EVENTS_ARN "$SNS_EV"
ok "SNS 이벤트 주제: $SNS_EV"

aws sqs set-queue-attributes --queue-url "$SQS_URL" --attributes "$(jq -nc \
  --arg q "$SQS_ARN" --arg t "$SNS_EV" \
  '{Policy:({Version:"2012-10-17",Id:"capstone-sqs-policy",Statement:[
     {Sid:"AllowSnsSend",Effect:"Allow",Principal:{Service:"sns.amazonaws.com"},
      Action:"sqs:SendMessage",Resource:$q,
      Condition:{ArnEquals:{"aws:SourceArn":$t}}}]}|tostring)}')" >/dev/null
ok "SQS 큐 정책: SNS 발행 허용"

if ! aws sns list-subscriptions-by-topic --topic-arn "$SNS_EV" --query 'Subscriptions[].Endpoint' --output text 2>/dev/null | grep -q "$SQS_ARN"; then
  aws sns subscribe --topic-arn "$SNS_EV" --protocol sqs --notification-endpoint "$SQS_ARN" \
    --attributes RawMessageDelivery=true >/dev/null
  ok "SNS → SQS 구독 생성"
else skip "SNS → SQS 구독"; fi

# ---------- 3. Lambda 역할 ----------
L_TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
if aws iam get-role --role-name "$N_ROLE_LAMBDA" >/dev/null 2>&1; then skip "역할 $N_ROLE_LAMBDA"
else
  aws iam create-role --role-name "$N_ROLE_LAMBDA" --assume-role-policy-document "$L_TRUST" \
    --tags Key=Project,Value=capstone Key=Owner,Value="$PREFIX" >/dev/null
  ok "Lambda 역할 생성"
fi
aws iam attach-role-policy --role-name "$N_ROLE_LAMBDA" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole >/dev/null 2>&1 || true
aws iam attach-role-policy --role-name "$N_ROLE_LAMBDA" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaSQSQueueExecutionRole >/dev/null 2>&1 || true
L_ROLE_ARN="$(_q aws iam get-role --role-name "$N_ROLE_LAMBDA" --query Role.Arn --output text)"
save_state LAMBDA_ROLE_ARN "$L_ROLE_ARN"

# ---------- 4. Lambda 함수 ----------
TMP="$(mktemp -d)"
cat > "$TMP/index.py" << 'PY'
import json, os, datetime

def handler(event, context):
    # ---- SQS 이벤트 소스 매핑 경로 ----
    if "Records" in event and event["Records"] and "body" in event["Records"][0]:
        for r in event["Records"]:
            body = r.get("body", "")
            print("SQS message:", body)
            # DLQ 실습용: force_error 가 있는 메시지는 일부러 실패시킨다.
            # 3회 재시도 후 배달 못 한 편지 큐로 이동하는 것을 관찰할 수 있다.
            try:
                if json.loads(body).get("force_error"):
                    raise RuntimeError("의도된 처리 실패 (DLQ 실습)")
            except json.JSONDecodeError:
                pass
        return {"processed": len(event["Records"])}

    # ---- API Gateway 프록시 경로 ----
    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({
            "service": "capstone",
            "path": event.get("path") or event.get("rawPath", "/"),
            "time": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "requestId": getattr(context, "aws_request_id", "-"),
        }),
    }
PY
(cd "$TMP" && zip -q function.zip index.py)

if aws lambda get-function --function-name "$N_LAMBDA" >/dev/null 2>&1; then
  aws lambda update-function-code --function-name "$N_LAMBDA" \
    --zip-file "fileb://$TMP/function.zip" >/dev/null
  skip "Lambda $N_LAMBDA (코드 갱신)"
else
  # 두 가지 실패가 겹칠 수 있다. 원인을 정확히 구분해야 한다.
  #   1) IAM 역할 전파 지연 — 같은 런타임으로 기다렸다 재시도
  #   2) 런타임 미지원      — 다음 런타임 후보로 교체
  # 오류 문구를 정확히 보고 판단한다. 예외 유형(InvalidParameterValueException)은
  # 두 경우 모두에서 나오므로 유형만으로 갈라서는 안 된다.
  CREATED=0
  RUNTIMES="${LAMBDA_RUNTIME:-python3.13} python3.12 python3.11"
  for RT in $RUNTIMES; do
    for attempt in 1 2 3 4 5 6; do
      if LERR="$(aws lambda create-function --function-name "$N_LAMBDA" \
                  --runtime "$RT" --handler index.handler --role "$L_ROLE_ARN" \
                  --zip-file "fileb://$TMP/function.zip" --timeout 30 --memory-size 256 \
                  --tags Project=capstone,Lab=$LAB,Owner="$PREFIX" 2>&1 >/dev/null)"; then
        ok "Lambda 생성: $N_LAMBDA (런타임 $RT)"
        save_state LAMBDA_RUNTIME_USED "$RT"
        CREATED=1; break 2
      fi
      case "$LERR" in
        *"cannot be assumed"*|*"KMSAccessDenied"*|*"role defined for the function"*)
          log "  IAM 역할 전파 대기 (${attempt}/6)"; sleep 10; continue ;;
        *"Runtime"*"not supported"*|*"runtime"*"not supported"*|*"Unsupported runtime"*)
          warn "런타임 $RT 미지원 — 다음 후보로 교체"; break ;;
        *ResourceConflictException*)
          skip "Lambda $N_LAMBDA (이미 존재)"; CREATED=1; break 2 ;;
        *)
          err "Lambda 생성 실패 — 런타임과 무관한 오류입니다"
          printf '      %s\n' "$LERR" >&2
          err "  역할: $L_ROLE_ARN"
          exit 1 ;;
      esac
    done
  done
  [ "$CREATED" = "1" ] || die "Lambda 생성에 실패했습니다"
fi
rm -rf "$TMP"
aws lambda wait function-active-v2 --function-name "$N_LAMBDA" 2>/dev/null || true
L_ARN="$(_q aws lambda get-function --function-name "$N_LAMBDA" --query 'Configuration.FunctionArn' --output text)"
save_state LAMBDA_ARN "$L_ARN"

# ---------- 5. SQS → Lambda 이벤트 소스 매핑 ----------
if aws lambda list-event-source-mappings --function-name "$N_LAMBDA" \
     --query "EventSourceMappings[?EventSourceArn=='$SQS_ARN'] | length(@)" --output text 2>/dev/null | grep -q '^0$'; then
  aws lambda create-event-source-mapping --function-name "$N_LAMBDA" \
    --event-source-arn "$SQS_ARN" --batch-size 10 >/dev/null
  ok "이벤트 소스 매핑 생성 (SQS → Lambda)"
else skip "이벤트 소스 매핑"; fi

# ---------- 6. API Gateway (HTTP API + Lambda 프록시) ----------
API_ID="$(_q aws apigatewayv2 get-apis --query "Items[?Name=='$N_APIGW'].ApiId | [0]" --output text)"
if [ -z "$API_ID" ]; then
  API_ID="$(aws apigatewayv2 create-api --name "$N_APIGW" --protocol-type HTTP \
    --target "$L_ARN" --tags Project=capstone,Lab=$LAB,Owner="$PREFIX" \
    --query ApiId --output text)"
  ok "API Gateway(HTTP API) 생성: $API_ID"
else skip "API Gateway ($API_ID)"; fi
save_state APIGW_ID "$API_ID"
aws lambda add-permission --function-name "$N_LAMBDA" --statement-id apigw-invoke \
  --action lambda:InvokeFunction --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT_ID}:${API_ID}/*" >/dev/null 2>&1 \
  && ok "Lambda 호출 권한 부여 (API Gateway)" || skip "Lambda 호출 권한"
API_EP="$(_q aws apigatewayv2 get-api --api-id "$API_ID" --query ApiEndpoint --output text)"
save_state APIGW_ENDPOINT "$API_EP"
ok "API 엔드포인트: $API_EP"

# ---------- 7. S3 이벤트 → SNS ----------
# SNS 는 정책의 각 문장에 고유한 Sid 를 요구한다(S3·SQS 정책과 다른 점).
SNS_POLICY="$(jq -nc \
  --arg t "$SNS_EV" --arg b "arn:aws:s3:::${BUCKET_WEB}" --arg a "$ACCOUNT_ID" \
  '{Version:"2012-10-17",Id:"capstone-sns-policy",Statement:[
    {Sid:"AllowS3Publish",Effect:"Allow",Principal:{Service:"s3.amazonaws.com"},
     Action:"SNS:Publish",Resource:$t,
     Condition:{ArnLike:{"aws:SourceArn":$b},StringEquals:{"aws:SourceAccount":$a}}},
    {Sid:"AllowOwnerSubscribe",Effect:"Allow",Principal:{AWS:"*"},
     Action:["SNS:Subscribe","SNS:Receive"],Resource:$t,
     Condition:{StringEquals:{"AWS:SourceOwner":$a}}}]}')"
printf '%s' "$SNS_POLICY" | jq -e . >/dev/null || die "SNS 정책 JSON 생성 실패"

if SERR="$(aws sns set-topic-attributes --topic-arn "$SNS_EV" \
            --attribute-name Policy --attribute-value "$SNS_POLICY" 2>&1 >/dev/null)"; then
  ok "SNS 주제 정책: S3 발행 허용"
else
  err "SNS 주제 정책 적용 실패"
  printf '      %s\n' "$SERR" >&2
  exit 1
fi

aws s3api put-bucket-notification-configuration --bucket "$BUCKET_WEB" \
  --notification-configuration "$(jq -nc --arg t "$SNS_EV" \
   '{TopicConfigurations:[{Id:"upload-event",TopicArn:$t,Events:["s3:ObjectCreated:*"],
     Filter:{Key:{FilterRules:[{Name:"prefix",Value:"uploads/"}]}}}]}')" >/dev/null \
  && ok "S3 이벤트 알림 구성 (uploads/ → SNS)" || warn "S3 이벤트 알림 구성 실패"

# ---------- 8. CloudFront에 /api/* 경로 추가 ----------
# Lab 11의 배포에 API Gateway 오리진을 붙인다. 사용자는 한 도메인만 쓰면 된다.
#   /            → ALB(Tomcat)
#   /static/*    → S3
#   /api/*       → API Gateway(Lambda)
if [ -n "${CLOUDFRONT_ID:-}" ] && [ -n "$API_EP" ]; then
  API_HOST="${API_EP#https://}"; API_HOST="${API_HOST%%/*}"
  ETAG="$(_q aws cloudfront get-distribution-config --id "$CLOUDFRONT_ID" --query 'ETag' --output text)"
  CUR="$(aws cloudfront get-distribution-config --id "$CLOUDFRONT_ID" --query 'DistributionConfig' --output json 2>/dev/null)"

  if [ -n "$ETAG" ] && [ -n "$CUR" ]; then
    HAS_API="$(printf '%s' "$CUR" | jq -r '[.CacheBehaviors.Items[]? | select(.PathPattern=="/api/*")] | length')"
    if [ "${HAS_API:-0}" = "0" ]; then
      CP_OFF="$(aws cloudfront list-cache-policies --type managed --output json 2>/dev/null \
        | jq -r '[.CachePolicyList.Items[]? | select(.CachePolicy.CachePolicyConfig.Name|test("CachingDisabled$")) | .CachePolicy.Id] | first // "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"')"
      ORP_AV="$(aws cloudfront list-origin-request-policies --type managed --output json 2>/dev/null \
        | jq -r '[.OriginRequestPolicyList.Items[]? | select(.OriginRequestPolicy.OriginRequestPolicyConfig.Name|test("AllViewerExceptHostHeader$")) | .OriginRequestPolicy.Id] | first // empty')"

      NEW_CFG="$(printf '%s' "$CUR" | jq \
        --arg host "$API_HOST" --arg cp "$CP_OFF" --arg orp "${ORP_AV:-}" '
        # 오리진도 마찬가지로 기존 ALB 오리진을 본떠 필수 필드를 빠뜨리지 않는다.
        ([.Origins.Items[] | select(.CustomOriginConfig != null)] | first) as $obase
        | .Origins.Items += [
            (($obase // {}) 
             + {Id:"api-origin", DomainName:$host, OriginPath:"",
                CustomHeaders:{Quantity:0},
                CustomOriginConfig:(($obase.CustomOriginConfig // {})
                  + {HTTPPort:80, HTTPSPort:443, OriginProtocolPolicy:"https-only",
                     OriginSslProtocols:{Quantity:1, Items:["TLSv1.2"]},
                     OriginReadTimeout:30, OriginKeepaliveTimeout:5})})]
        | .Origins.Quantity = (.Origins.Items | length)
        # update-distribution 은 캐시 동작의 필수 필드를 모두 요구한다
        # (SmoothStreaming, FieldLevelEncryptionId 등). 기존 동작을 본떠 만들어
        # 스키마가 바뀌어도 빠지는 필드가 없게 한다.
        | (.DefaultCacheBehavior) as $base
        | .CacheBehaviors.Items = ((.CacheBehaviors.Items // []) + [
            ($base
             | del(.CachePolicyId, .OriginRequestPolicyId, .ResponseHeadersPolicyId,
                   .ForwardedValues, .MinTTL, .DefaultTTL, .MaxTTL)
             + {PathPattern:"/api/*", TargetOriginId:"api-origin",
                ViewerProtocolPolicy:"redirect-to-https",
                AllowedMethods:{Quantity:7, Items:["GET","HEAD","OPTIONS","PUT","POST","PATCH","DELETE"],
                                CachedMethods:{Quantity:2, Items:["GET","HEAD"]}},
                CachePolicyId:$cp, Compress:true}
             + (if $orp == "" then {} else {OriginRequestPolicyId:$orp} end))])
        | .CacheBehaviors.Quantity = (.CacheBehaviors.Items | length)')"

      if printf '%s' "$NEW_CFG" | jq -e . >/dev/null 2>&1; then
        UERR="$(aws cloudfront update-distribution --id "$CLOUDFRONT_ID" \
                 --distribution-config "$NEW_CFG" --if-match "$ETAG" 2>&1 >/dev/null)" \
          && { ok "CloudFront에 /api/* 경로 추가 (오리진: $API_HOST)"
               log "  전파에 5~15분 걸립니다."
               save_state CF_API_ADDED 1; } \
          || { warn "CloudFront 갱신 실패"; printf '      %s\n' "$UERR" | head -5 >&2; }
      else
        warn "CloudFront 설정 JSON 생성 실패 — /api/* 추가를 건너뜁니다"
      fi
    else
      skip "CloudFront /api/* 경로"
    fi
  else
    warn "CloudFront 설정 조회 실패 — /api/* 추가를 건너뜁니다"
  fi
else
  log "CloudFront(Lab 11) 미구성 — API Gateway 직접 주소만 사용합니다"
fi

save_state LAB12_DONE 1

if [ -n "${CLOUDFRONT_DOMAIN:-}" ]; then
  CF_API_URL="https://${CLOUDFRONT_DOMAIN}/api/"
else
  CF_API_URL="(Lab 11 미구성)"
fi

banner "구성 완료"
cat << GUIDE
  API 직접:     ${API_EP}/
  CloudFront:   ${CF_API_URL}

  이벤트 파이프라인
    S3(uploads/) → SNS(${N_SNS_EVENTS}) → SQS(${N_SQS}) → Lambda(${N_LAMBDA}) → CloudWatch Logs

  확인할 것
    1) API 응답
         curl -s ${API_EP}/ | jq .

    2) 파이프라인 종단 시험 — S3에 파일을 올리면 Lambda 로그에 나타난다
         date +%s > /tmp/t.txt
         aws s3 cp /tmp/t.txt s3://${BUCKET_WEB}/uploads/t.txt
         sleep 20
         aws logs tail /aws/lambda/${N_LAMBDA} --since 2m

    3) 큐에 남은 메시지 확인
         aws sqs get-queue-attributes --queue-url ${SQS_URL} \
           --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible

    4) DLQ 동작 — 처리 실패가 3회 반복되면 배달 못 한 편지 큐로 간다
         bash lab12-serverless/verify.sh   (DLQ_TEST=1 로 실행하면 실제로 시험)
GUIDE
ok "Lab 12 완료"
