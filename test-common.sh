#!/usr/bin/env bash
# ============================================================
# test-common.sh — 00-common 4개 파일 단위 검증
#   PATH에 목 aws 를 얹고 실행:  PATH=/home/claude/mock:$PATH bash test-common.sh
# ============================================================
TESTS=0; FAILS=0
R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; Z=$'\033[0m'

t() { # t "설명" 기대값 실제값
  TESTS=$((TESTS+1))
  if [ "$2" = "$3" ]; then printf '  %sPASS%s %s\n' "$G" "$Z" "$1"
  else printf '  %sFAIL%s %s\n       기대[%s] 실제[%s]\n' "$R" "$Z" "$1" "$2" "$3"; FAILS=$((FAILS+1)); fi
}
trun() { # trun "설명" 기대종료코드 <명령...>
  TESTS=$((TESTS+1)); local d="$1" want="$2"; shift 2
  "$@" >/dev/null 2>&1; local got=$?
  if [ "$got" = "$want" ]; then printf '  %sPASS%s %s\n' "$G" "$Z" "$d"
  else printf '  %sFAIL%s %s (종료코드 기대 %s / 실제 %s)\n' "$R" "$Z" "$d" "$want" "$got"; FAILS=$((FAILS+1)); fi
}
sec() { printf '\n%s── %s%s\n' "$Y" "$1" "$Z"; }

HERE="$(cd "$(dirname "$0")" && pwd)"
export TESTROOT="$(mktemp -d)"
cp -r "$HERE/00-common" "$TESTROOT/"
mkdir -p "$TESTROOT/state"

# ============================================================
sec "1. env.sh — 변수 유도"
# ============================================================
out="$(PREFIX=st07 STUDENT_BASE=21 REGION=ap-northeast-2 \
  bash -c ". $TESTROOT/00-common/env.sh; echo \"\$VPC_SVC_CIDR|\$VPC_MGMT_CIDR|\$SN_SVC_APP_A_CIDR|\$N_VPC_SVC|\$AZ_A|\$STATE_FILE\"" 2>&1)"
IFS='|' read -r c1 c2 c3 n1 az sf <<< "$out"
t "서비스 VPC CIDR 계산"        "10.21.0.0/16"  "$c1"
t "관리 VPC CIDR 계산"          "10.22.0.0/16"  "$c2"
t "App-a 서브넷 CIDR 계산"      "10.21.10.0/24" "$c3"
t "PREFIX가 리소스명에 반영"    "st07-vpc-svc"  "$n1"
t "AZ_A 자동 유도"              "ap-northeast-2a" "$az"
t "state 파일이 PREFIX별 분리"  "st07.env"      "$(basename "$sf")"

out="$(PREFIX=cap bash -c ". $TESTROOT/00-common/env.sh; echo \"[\$AWS_PAGER],\$AWS_DEFAULT_REGION\"")"
t "AWS_PAGER 무력화"            "[],ap-northeast-2" "$out"

out="$(REGION=us-west-2 bash -c ". $TESTROOT/00-common/env.sh; echo \$AZ_A,\$AZ_C")"
t "리전 변경 시 AZ 추종"        "us-west-2a,us-west-2c" "$out"

# 학생별 격리: 서로 다른 STUDENT_BASE가 CIDR 충돌을 일으키지 않는가
a="$(STUDENT_BASE=1  bash -c ". $TESTROOT/00-common/env.sh; echo \$VPC_SVC_CIDR \$VPC_MGMT_CIDR")"
b="$(STUDENT_BASE=3  bash -c ". $TESTROOT/00-common/env.sh; echo \$VPC_SVC_CIDR \$VPC_MGMT_CIDR")"
t "STUDENT_BASE=1 대역"         "10.1.0.0/16 10.2.0.0/16" "$a"
t "STUDENT_BASE=3 대역(비충돌)" "10.3.0.0/16 10.4.0.0/16" "$b"

# ============================================================
sec "2. lib.sh — 상태 파일"
# ============================================================
export PREFIX=t1
SF="$TESTROOT/state/t1.env"; rm -f "$SF"
runlib() { PREFIX=t1 bash -c ". $TESTROOT/00-common/env.sh; . $TESTROOT/00-common/lib.sh; $1"; }

runlib 'save_state VPC_SVC vpc-aaa' >/dev/null
t "save_state 기록"             "export VPC_SVC=vpc-aaa" "$(cat "$SF")"

runlib 'save_state VPC_SVC vpc-bbb' >/dev/null
t "save_state 덮어쓰기(중복 없음)" "1" "$(grep -c '^export VPC_SVC=' "$SF")"
t "덮어쓴 값 반영"              "export VPC_SVC=vpc-bbb" "$(cat "$SF")"

runlib 'save_state EMPTY ""' >/dev/null 2>&1
t "빈 값은 저장하지 않음"       "0" "$(grep -c '^export EMPTY=' "$SF")"
runlib 'save_state NONEVAL None' >/dev/null 2>&1
t "None 값은 저장하지 않음"     "0" "$(grep -c '^export NONEVAL=' "$SF")"

runlib 'save_state ARN "arn:aws:iam::123:role/a b"' >/dev/null
t "공백 포함 값 안전 저장"      "arn:aws:iam::123:role/a b" \
  "$(runlib 'load_state; echo "$ARN"')"

runlib 'save_state K2 v2' >/dev/null
runlib 'drop_state VPC_SVC' >/dev/null
t "drop_state 대상만 제거"      "0" "$(grep -c '^export VPC_SVC=' "$SF")"
t "drop_state 후 타 키 보존"    "1" "$(grep -c '^export K2=' "$SF")"

t "load_state 복원"             "v2" "$(runlib 'load_state; echo "$K2"')"
rm -f "$SF"
t "state 파일 없을 때 load_state 무해" "0" \
  "$(runlib 'load_state; echo $?')"

# ============================================================
sec "3. lib.sh — need_state 게이트"
# ============================================================
rm -f "$SF"; runlib 'save_state VPC_SVC vpc-x' >/dev/null
trun "선행 산출물 있으면 통과"  0 bash -c \
  "PREFIX=t1; . $TESTROOT/00-common/env.sh; . $TESTROOT/00-common/lib.sh; load_state; need_state VPC_SVC"
trun "선행 산출물 없으면 중단"  1 bash -c \
  "PREFIX=t1; . $TESTROOT/00-common/env.sh; . $TESTROOT/00-common/lib.sh; load_state; need_state VPC_SVC SG_APP"
msg="$(bash -c "PREFIX=t1; . $TESTROOT/00-common/env.sh; . $TESTROOT/00-common/lib.sh; load_state; need_state SG_APP" 2>&1)"
case "$msg" in *"build-all.sh"*) t "실패 시 복구 방법 안내" "yes" "yes";; *) t "실패 시 복구 방법 안내" "yes" "no";; esac

# ============================================================
sec "4. lib.sh — 태그 규격"
# ============================================================
ts="$(runlib 'tagspec vpc cap-vpc-svc 2')"
t "tagspec 형식" \
  "ResourceType=vpc,Tags=[{Key=Name,Value=cap-vpc-svc},{Key=Project,Value=capstone},{Key=Lab,Value=2},{Key=Owner,Value=t1}]" "$ts"
case "$ts" in *"Key=Owner"*) t "Owner 태그 포함(teardown 기준)" yes yes;; *) t "Owner 태그 포함(teardown 기준)" yes no;; esac

# ============================================================
sec "5. lib.sh — _q 정규화 및 조회 헬퍼"
# ============================================================
export PATH="/home/claude/mock:$PATH"
rm -f /tmp/mock-aws-db.json
v="$(runlib '_q aws ec2 describe-vpcs --filters Name=tag:Name,Values=nope --query "Vpcs[0].VpcId" --output text')"
t "존재하지 않으면 빈 문자열"   "" "$v"
v="$(runlib 'vpc_id_by_name nope; echo "[$?]"')"
t "vpc_id_by_name 실패해도 종료 안 함" "[0]" "$v"
v="$(runlib 'x=$(_q aws nonexistent-service bogus-cmd); echo "ok:$x"')"
t "_q는 실패 명령에도 종료 0"   "ok:" "$v"

# ============================================================
sec "6. lib.sh — check/verify 채점기"
# ============================================================
out="$(runlib 'check_begin "L"; check "참" true; check "거짓" false; check_summary' 2>&1)"
case "$out" in *"PASS"*) t "check PASS 출력" yes yes;; *) t "check PASS 출력" yes no;; esac
case "$out" in *"FAIL"*) t "check FAIL 출력" yes yes;; *) t "check FAIL 출력" yes no;; esac
case "$out" in *"1/2"*) t "합계 집계 정확" yes yes;; *) t "합계 집계 정확 (실제: $out)" yes no;; esac
trun "전부 통과 시 종료코드 0"  0 bash -c \
  "PREFIX=t1; . $TESTROOT/00-common/env.sh; . $TESTROOT/00-common/lib.sh; check_begin L; check a true; check_summary"
trun "하나라도 실패 시 종료코드 1" 1 bash -c \
  "PREFIX=t1; . $TESTROOT/00-common/env.sh; . $TESTROOT/00-common/lib.sh; check_begin L; check a false; check_summary"
out="$(runlib 'check_begin L; check_eq "값비교" 3 echo 5' 2>&1)"
case "$out" in *"기대 3"*"실제 5"*) t "check_eq 기대/실제 표시" yes yes;; *) t "check_eq 기대/실제 표시" yes no;; esac

# ============================================================
sec "7. lib.sh — 대기·재시도"
# ============================================================
trun "wait_until 즉시 성공"     0 bash -c \
  "PREFIX=t1; . $TESTROOT/00-common/env.sh; . $TESTROOT/00-common/lib.sh; wait_until d 10 1 true"
trun "wait_until 시간 초과 시 1" 1 bash -c \
  "PREFIX=t1; . $TESTROOT/00-common/env.sh; . $TESTROOT/00-common/lib.sh; wait_until d 2 1 false"
trun "retry 소진 시 1"          1 bash -c \
  "PREFIX=t1; . $TESTROOT/00-common/env.sh; . $TESTROOT/00-common/lib.sh; retry 2 0 false"
out="$(runlib 'n=0; f(){ n=$((n+1)); [ $n -ge 2 ]; }; retry 3 0 f && echo ok')"
t "retry 2회차 성공"            "ok" "$out"
trun "soft는 실패해도 0"        0 bash -c \
  "PREFIX=t1; . $TESTROOT/00-common/env.sh; . $TESTROOT/00-common/lib.sh; soft false"

# ============================================================
sec "8. guard.sh — 오폭 방지"
# ============================================================
G_RUN() { bash -c "export AWS_PROFILE=capstone; . $TESTROOT/00-common/env.sh; . $TESTROOT/00-common/lib.sh; . $TESTROOT/00-common/guard.sh; guard" 2>&1; }
trun "허용 계정이면 통과"       0 bash -c \
  "export AWS_PROFILE=capstone MOCK_ACCOUNT=676206941602; . $TESTROOT/00-common/env.sh; . $TESTROOT/00-common/lib.sh; . $TESTROOT/00-common/guard.sh; guard"
trun "허용 목록 밖 계정이면 중단" 1 bash -c \
  "export AWS_PROFILE=capstone MOCK_ACCOUNT=999999999999; . $TESTROOT/00-common/env.sh; . $TESTROOT/00-common/lib.sh; . $TESTROOT/00-common/guard.sh; guard"
trun "복수 계정 허용 목록 동작" 0 bash -c \
  "export AWS_PROFILE=capstone MOCK_ACCOUNT=111122223333 EXPECTED_ACCOUNT_IDS='676206941602,111122223333'; . $TESTROOT/00-common/env.sh; . $TESTROOT/00-common/lib.sh; . $TESTROOT/00-common/guard.sh; guard"
trun "없는 AZ 지정 시 중단"     1 bash -c \
  "export AWS_PROFILE=capstone AZ_C=ap-northeast-2z; . $TESTROOT/00-common/env.sh; . $TESTROOT/00-common/lib.sh; . $TESTROOT/00-common/guard.sh; guard"
out="$(MOCK_ACCOUNT=999999999999 G_RUN)"
case "$out" in *999999999999*676206941602*) t "불일치 시 양쪽 계정 표시" yes yes;; *) t "불일치 시 양쪽 계정 표시" yes no;; esac
out="$(bash -c "export AWS_PROFILE=default; . $TESTROOT/00-common/env.sh; . $TESTROOT/00-common/lib.sh; . $TESTROOT/00-common/guard.sh; guard" 2>&1)"
case "$out" in *"기본 프로파일"*) t "기본 프로파일 경고" yes yes;; *) t "기본 프로파일 경고" yes no;; esac
out="$(G_RUN)"
case "$out" in *"ACCOUNT_ID"*|*676206941602*) t "guard가 ACCOUNT_ID 노출" yes yes;; *) t "guard가 ACCOUNT_ID 노출" yes no;; esac
t "guard 후 ACCOUNT_ID 사용 가능" "676206941602" \
  "$(bash -c "export AWS_PROFILE=capstone; . $TESTROOT/00-common/env.sh; . $TESTROOT/00-common/lib.sh; . $TESTROOT/00-common/guard.sh; guard >/dev/null; echo \$ACCOUNT_ID")"

# ============================================================
sec "9. bootstrap.sh — 통합 로딩"
# ============================================================
trun "bootstrap 단독 source 성공" 0 bash -c \
  "export AWS_PROFILE=capstone; . $TESTROOT/00-common/bootstrap.sh"
t "엄격 모드(set -e) 적용" "euo" \
  "$(bash -c "export AWS_PROFILE=capstone; . $TESTROOT/00-common/bootstrap.sh; o=''; case \$- in *e*) o=\${o}e;; esac; case \$- in *u*) o=\${o}u;; esac; set -o | grep -q 'pipefail.*on' && o=\${o}o; echo \$o")"
trun "미정의 변수 참조 시 중단(set -u)" 1 bash -c \
  "export AWS_PROFILE=capstone; . $TESTROOT/00-common/bootstrap.sh; echo \$NEVER_DEFINED"
t "bootstrap이 state 자동 복원" "vpc-x" \
  "$(PREFIX=t1 bash -c "export AWS_PROFILE=capstone; . $TESTROOT/00-common/bootstrap.sh; echo \${VPC_SVC:-없음}")"
t "ROOT_DIR 산출" "$TESTROOT" \
  "$(bash -c "export AWS_PROFILE=capstone; . $TESTROOT/00-common/bootstrap.sh; echo \$ROOT_DIR")"
trun "bootstrap은 guard를 자동 실행하지 않음" 0 bash -c \
  "export AWS_PROFILE=capstone MOCK_ACCOUNT=999999999999; . $TESTROOT/00-common/bootstrap.sh"

# ============================================================
sec "10. 회귀 — 이전에 발견된 버그"
# ============================================================
t "AZ 목록 탭 구분자 파싱" "0" \
  "$(bash -c "export AWS_PROFILE=capstone; . $TESTROOT/00-common/env.sh; . $TESTROOT/00-common/lib.sh; . $TESTROOT/00-common/guard.sh; ( guard ) >/dev/null 2>&1; echo \$?")"
t "허용 목록 마지막 항목 불일치 시 정상 안내" "1" \
  "$(bash -c "export AWS_PROFILE=capstone MOCK_ACCOUNT=555 EXPECTED_ACCOUNT_IDS='111,222'; . $TESTROOT/00-common/env.sh; . $TESTROOT/00-common/lib.sh; . $TESTROOT/00-common/guard.sh; ( guard ) >/dev/null 2>&1; echo \$?")"
out="$(bash -c "export AWS_PROFILE=capstone MOCK_ACCOUNT=222 EXPECTED_ACCOUNT_IDS='111, 222'; . $TESTROOT/00-common/env.sh; . $TESTROOT/00-common/lib.sh; . $TESTROOT/00-common/guard.sh; ( guard ) >/dev/null 2>&1; echo \$?")"
t "허용 목록 공백 허용('111, 222')" "0" "$out"

# ============================================================
printf '\n%s================================================%s\n' "$Y" "$Z"
if [ "$FAILS" -eq 0 ]; then
  printf ' %s전체 통과  %d/%d%s\n' "$G" "$TESTS" "$TESTS" "$Z"
else
  printf ' %s실패 %d건 / 전체 %d건%s\n' "$R" "$FAILS" "$TESTS" "$Z"
fi
printf '%s================================================%s\n' "$Y" "$Z"
rm -rf "$TESTROOT"
[ "$FAILS" -eq 0 ]
