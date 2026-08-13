#!/usr/bin/env bash
# ============================================================
# bootstrap.sh — 각 랩 스크립트의 첫 3줄을 이 한 줄로 대체한다.
#   source "$(dirname "$0")/../00-common/bootstrap.sh"
# env → lib → guard 로드 + state 복원 + 엄격 모드 설정까지 한 번에 처리.
# ============================================================
set -euo pipefail

_BS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
. "$_BS_DIR/env.sh"
# shellcheck source=/dev/null
. "$_BS_DIR/lib.sh"
# shellcheck source=/dev/null
. "$_BS_DIR/guard.sh"
# shellcheck source=/dev/null
. "$_BS_DIR/state-sync.sh"

load_state
