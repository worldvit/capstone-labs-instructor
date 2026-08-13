#!/usr/bin/env bash
# repair.sh — 누락된 리소스만 생성한다. build.sh가 멱등이므로 그대로 재호출한다.
DIR="$(cd "$(dirname "$0")" && pwd)"
echo "[repair] $(basename "$DIR") — 누락 리소스만 생성합니다."
exec bash "$DIR/build.sh" "$@"
