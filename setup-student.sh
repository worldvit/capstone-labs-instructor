#!/usr/bin/env bash
# ============================================================
# setup-student.sh — 첫날 한 번만 실행하는 초기 설정
#
#   bash setup-student.sh
#
# 하는 일:
#   1. 지금 로그인한 계정번호를 알아낸다
#   2. student.env 를 만들어 그 번호를 채운다
#   3. CloudShell 을 다시 열어도 유지되게 .bashrc 에 건다
#
# 계정번호를 손으로 옮겨 적다 한 자리를 틀리는 일을 막는다.
# ============================================================
set -uo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"

export AWS_PAGER=""

C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_0=$'\033[0m'
ok()   { printf '%s[✔]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_0" "$*"; }
die()  { printf '%s[✘]%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
log()  { printf '[·] %s\n' "$*"; }

printf '\n================================================================\n'
printf ' 실습 환경 초기 설정\n'
printf '================================================================\n\n'

# ---------- 1. 계정번호 확인 ----------
ACCT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
ARN="$(aws sts get-caller-identity --query Arn --output text 2>/dev/null)"

if [ -z "$ACCT" ] || [ "$ACCT" = "None" ]; then
  die "AWS 자격 증명을 찾을 수 없습니다. CloudShell 에서 실행하고 있는지 확인하십시오."
fi

case "$ACCT" in
  [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) : ;;
  *) die "계정번호 형식이 이상합니다: $ACCT" ;;
esac

ok "계정번호 확인: $ACCT"
log "  사용자: $ARN"

# ---------- 2. 기존 파일 확인 ----------
if [ -f student.env ]; then
  OLD="$(grep -oE 'EXPECTED_ACCOUNT_IDS=[0-9]+' student.env | cut -d= -f2)"
  if [ "$OLD" = "$ACCT" ]; then
    ok "student.env 가 이미 이 계정으로 설정되어 있습니다."
  else
    warn "student.env 가 이미 있습니다 (계정: ${OLD:-비어 있음})"
    printf '    덮어쓰시겠습니까? [y/N] '
    read -r ans
    case "$ans" in
      [yY]) cp student.env "student.env.bak.$(date +%s)"
            log "  기존 파일을 student.env.bak.* 로 백업했습니다." ;;
      *)    log "  그대로 두었습니다. 종료합니다."; exit 0 ;;
    esac
  fi
fi

# ---------- 3. student.env 생성 ----------
cat > student.env << ENVEOF
# 이 파일은 setup-student.sh 가 만들었습니다.
# 계정번호는 실행 시점의 값으로 채워졌습니다.

# ---------- 필수 ----------
# 본인 AWS 계정번호. 다른 계정에 리소스를 만드는 사고를 막습니다.
export EXPECTED_ACCOUNT_IDS=$ACCT

# ---------- 기본값 ----------
export REGION=ap-northeast-2
export PREFIX=cap
export STUDENT_BASE=1

# ---------- 선택 ----------
# 리소스 ID 를 S3 에 백업해 다른 PC 에서 이어하려면 채우십시오.
export STATE_SYNC=0
export STATE_BUCKET=
ENVEOF
ok "student.env 생성 완료"

# ---------- 4. state 디렉터리 ----------
mkdir -p state
ok "state 디렉터리 준비"

# ---------- 5. .bashrc 에 걸기 ----------
LINE="[ -f $ROOT/student.env ] && . $ROOT/student.env"
if grep -qF "$ROOT/student.env" ~/.bashrc 2>/dev/null; then
  ok ".bashrc 에 이미 등록되어 있습니다."
else
  printf '%s\n' "$LINE" >> ~/.bashrc
  ok ".bashrc 에 등록 — CloudShell 을 다시 열어도 유지됩니다."
fi

# ---------- 6. 값 확인용으로만 읽는다 ----------
# 여기서 source 해도 이 스크립트(자식 셸) 안에서만 유효하다.
# 부모 셸에 적용하려면 사용자가 직접 source 해야 한다.
# shellcheck disable=SC1091
. ./student.env

printf '\n================================================================\n'
printf ' 설정된 값\n'
printf '================================================================\n'
printf '  계정번호   %s\n' "$EXPECTED_ACCOUNT_IDS"
printf '  리전       %s\n' "$REGION"
printf '  접두사     %s\n' "$PREFIX"
printf '  서비스 VPC 10.%s.0.0/16\n' "$STUDENT_BASE"
printf '  관리 VPC   10.%s.0.0/16\n' "$((STUDENT_BASE + 1))"

printf '\n%s⚠ 반드시 지금 실행하십시오%s\n' "$C_R" "$C_0"
printf '  이 스크립트는 별도 셸에서 돌았으므로 지금 셸에는 값이 없습니다.\n\n'
printf '    %ssource student.env%s\n\n' "$C_G" "$C_0"
printf '  (CloudShell 을 다시 열 때는 .bashrc 가 알아서 읽습니다)\n'

printf '\n%s그다음%s\n' "$C_Y" "$C_0"
cat << NEXT
  bash preflight.sh           # 사전 점검

  실습은 문서를 보며 콘솔로 진행하십시오.
  결석 등으로 진도를 맞춰야 할 때만 아래를 씁니다.

  bash build-all.sh --list    # 랩 번호 확인
  bash build-all.sh 1         # Lab 1 까지 만들기
  bash verify-all.sh 1        # 채점
NEXT
printf '\n'
