#!/usr/bin/env bash
# diagram.sh — 계정의 실제 리소스로 drawio 아키텍처 다이어그램을 만든다.
#
#   bash tools/diagram.sh                    기본(Project=capstone 태그)
#   bash tools/diagram.sh --owner st01       특정 학생 것만
#   bash tools/diagram.sh --all              태그 무관 전체
#   bash tools/diagram.sh -o ~/arch.drawio   출력 경로 지정
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  printf '[X] source 하지 마십시오.  올바른 사용:  bash %s\n' "${BASH_SOURCE[0]}" >&2
  return 1 2>/dev/null || exit 1
fi
source "$(dirname "$0")/../00-common/bootstrap.sh"
set +e; set +o pipefail

command -v python3 >/dev/null || die "python3 가 필요합니다"

OUT="${PREFIX}-architecture-$(date +%Y%m%d-%H%M).drawio"
ARGS=(--region "$REGION" -o "$OUT")
while [ $# -gt 0 ]; do
  case "$1" in
    -o|--out) OUT="$2"; ARGS=(--region "$REGION" -o "$OUT"); shift 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

banner "아키텍처 다이어그램 생성"
python3 "$(dirname "$0")/gen-diagram.py" "${ARGS[@]}"
rc=$?
if [ $rc -eq 0 ] && [ -f "$OUT" ]; then
  ok "파일: $(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
  log "  CloudShell 에서는 우측 상단 Actions → Download file 로 내려받으십시오."
  log "  https://app.diagrams.net 에서 파일 → 열기 로 불러옵니다."
fi
exit $rc
