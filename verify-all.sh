#!/usr/bin/env bash
# verify-all.sh [끝랩번호]  — 전체 랩 상태 진단표
source "$(dirname "$0")/00-common/bootstrap.sh"

guard

TO="${1:-13}"
LABS=(dummy lab01-iam lab02-vpc lab03-network lab04-ec2 lab05-endpoint-tgw lab06-s3 lab07-efs \
      lab08-aurora lab09-observability lab10-alb-asg lab11-cloudfront-waf lab12-serverless lab13-backup)

banner "전체 진단  (접두사 $PREFIX / 계정 $ACCOUNT_ID / 리전 $REGION)"
TOTAL_FAIL=0; SUMMARY=""
for i in $(seq 1 "$TO"); do
  d="${LABS[$i]}"
  out="$(bash "$ROOT_DIR/$d/verify.sh" 2>&1)" && rc=0 || rc=1
  printf '%s\n' "$out"
  line="$(printf '%s' "$out" | grep -o '결과: [0-9]*/[0-9]*' | tail -1)"
  if [ "$rc" -eq 0 ]; then
    SUMMARY="${SUMMARY}\n  Lab $(printf '%2d' $i)  ${C_G}통과${C_0}   ${line}"
  else
    SUMMARY="${SUMMARY}\n  Lab $(printf '%2d' $i)  ${C_R}미충족${C_0} ${line}"
    TOTAL_FAIL=$((TOTAL_FAIL+1))
  fi
done

banner "요약"
printf '%b\n\n' "$SUMMARY"
if [ "$TOTAL_FAIL" -eq 0 ]; then
  ok "Lab 1~$TO 전체 통과"
else
  err "미충족 랩 ${TOTAL_FAIL}개 — 해당 랩의 repair.sh를 실행하세요."
  exit 1
fi
