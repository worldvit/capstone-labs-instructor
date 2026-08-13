#!/usr/bin/env bash
# teardown-all.sh [시작랩번호]  — 역순 삭제. 기본은 13→1 전체.
source "$(dirname "$0")/00-common/bootstrap.sh"

guard

# 위치 번호는 1부터. lab08b-3tier(3-Tier 기본)가 9번이며 이후가 한 칸씩 밀린다.
# 랩 이름을 직접 넘겨도 된다:  bash build-all.sh lab08b-3tier
LABS=(dummy lab01-iam lab02-vpc lab03-network lab04-ec2 lab05-endpoint-tgw lab06-s3 lab07-efs \
      lab08-aurora lab08b-3tier lab09-observability lab10-alb-asg lab11-cloudfront-waf \
      lab12-serverless lab13-backup)

# 번호 또는 랩 이름을 위치 번호로 바꾼다.
resolve_lab() {
  local v="$1" i
  case "$v" in
    ''|*[!0-9]*)
      for i in "${!LABS[@]}"; do [ "${LABS[$i]}" = "$v" ] && { printf '%s' "$i"; return 0; }; done
      for i in "${!LABS[@]}"; do case "${LABS[$i]}" in "$v"*) printf '%s' "$i"; return 0 ;; esac; done
      return 1 ;;
    *) printf '%s' "$v" ;;
  esac
}

list_labs() {
  printf '  %-4s %s\n' "번호" "랩"
  local i
  for i in $(seq 1 $(( ${#LABS[@]} - 1 ))); do printf '  %-4s %s\n' "$i" "${LABS[$i]}"; done
}

FROM="$(resolve_lab "${1:-14}")" || die "알 수 없는 랩: ${1:-}"

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
