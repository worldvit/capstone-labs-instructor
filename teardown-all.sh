#!/usr/bin/env bash
# teardown-all.sh [시작랩번호]  — 역순 삭제. 기본은 13→1 전체.
source "$(dirname "$0")/00-common/bootstrap.sh"

guard

FROM="${1:-13}"
LABS=(dummy lab01-iam lab02-vpc lab03-network lab04-ec2 lab05-endpoint-tgw lab06-s3 lab07-efs \
      lab08-aurora lab09-observability lab10-alb-asg lab11-cloudfront-waf lab12-serverless lab13-backup)

banner "역순 삭제: Lab $FROM → 1   (접두사 $PREFIX)"
warn "CloudFront 배포 비활성화에만 15분 이상 소요될 수 있습니다."
confirm_destroy "Lab $FROM 부터 Lab 1 까지 모든 리소스를 삭제합니다."
export FORCE=1   # 개별 스크립트에서 재확인하지 않음

for i in $(seq "$FROM" -1 1); do
  d="${LABS[$i]}"
  banner "▼ Lab $i — $d"
  bash "$ROOT_DIR/$d/teardown.sh" || warn "Lab $i teardown 중 오류 (계속 진행)"
  load_state
done
banner "전체 삭제 완료"
log "남은 상태: $STATE_FILE"
