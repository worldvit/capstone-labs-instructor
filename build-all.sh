#!/usr/bin/env bash
# build-all.sh [끝랩번호] [시작랩번호]
#   bash build-all.sh 7      → Lab 1~7 누적 구축
#   bash build-all.sh 7 5    → Lab 5~7만 구축
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

if [ "${1:-}" = "--list" ]; then banner "랩 목록"; list_labs; exit 0; fi
TO="$(resolve_lab "${1:-14}")"  || die "알 수 없는 랩: ${1:-}  (bash build-all.sh --list 로 확인)"
FROM="$(resolve_lab "${2:-1}")" || die "알 수 없는 랩: ${2:-}"
[ "$TO" -ge 1 ] && [ "$TO" -le 14 ] || die "랩 번호는 1~14 입니다. (bash build-all.sh --list)"


banner "누적 구축: Lab $FROM ~ $TO   (접두사 $PREFIX / 리전 $REGION)"
# 원격 state 동기화.
# 로컬이 더 최신인데 원격이 덮어쓰면 이미 만든 리소스의 ID 를 잃는다(실제로 겪은 사고).
# 로컬이 비었을 때만 자동으로 내려받고, 다르면 물어본다.
if [ "$STATE_SYNC" = "1" ]; then
  # grep -c 는 일치가 없으면 0 을 출력하고 종료코드 1 을 낸다.
  # `|| echo 0` 을 붙이면 "0\n0" 이 되어 산술 비교가 깨진다.
  LOCAL_KEYS=0
  if [ -f "$STATE_FILE" ]; then
    LOCAL_KEYS="$(grep -c '^export ' "$STATE_FILE" 2>/dev/null)" || LOCAL_KEYS=0
  fi
  LOCAL_KEYS="${LOCAL_KEYS//[^0-9]/}"; : "${LOCAL_KEYS:=0}"
  if [ "${LOCAL_KEYS:-0}" -eq 0 ]; then
    log "로컬 state 가 비어 있어 원격에서 내려받습니다"
    state_pull || true
  elif [ "${STATE_PULL:-ask}" = "force" ]; then
    warn "STATE_PULL=force — 원격으로 로컬을 덮어씁니다"
    state_pull || true
  elif [ "${STATE_PULL:-ask}" = "skip" ]; then
    log "STATE_PULL=skip — 로컬 state 를 그대로 씁니다 (${LOCAL_KEYS}개 키)"
  else
    log "로컬 state 에 ${LOCAL_KEYS}개 키가 있습니다. 원격을 내려받지 않습니다."
    log "  원격으로 덮어쓰려면:  STATE_PULL=force ...  /  비교:  bash 00-common/state-sync.sh status"
  fi
fi
START_TS=$(date +%s)
for i in $(seq "$FROM" "$TO"); do
  d="${LABS[$i]}"
  banner "▶ Lab $i — $d"
  t0=$(date +%s)
  if bash "$ROOT_DIR/$d/build.sh"; then
    ok "Lab $i 성공 ($(( $(date +%s) - t0 ))초)"
    [ "$STATE_SYNC" = "1" ] && state_push "${d}-done" || true
  else
    err "Lab $i 실패 — 중단합니다."
    err "  진단:  bash $d/verify.sh"
    err "  복구:  bash $d/repair.sh"
    exit 1
  fi
  load_state
done
banner "완료: Lab $FROM~$TO  총 $(( $(date +%s) - START_TS ))초"
log "상태 확인:  bash verify-all.sh $TO"
