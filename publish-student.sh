#!/usr/bin/env bash
# ============================================================
# publish-student.sh — 강사 저장소에서 학생 배포본을 생성한다.
#
#   bash publish-student.sh ../capstone-labs
#
# 강사 저장소가 원본(single source of truth)이다.
# 학생 저장소는 여기서 생성되는 파생물이며 직접 편집하지 않는다.
#
# 학생에게 나가는 것 : 00-common, preflight.sh, verify.sh, teardown.sh,
#                      setup-*.sh(플레이스홀더 상태), 문서
# 학생에게 안 나가는 것: build.sh, repair.sh, build-all.sh, mock-aws, test-common.sh
#
# setup-*.sh 를 내보내는 이유:
#   따라하기형 실습 문서가 이 스크립트를 sed 로 치환해 쓰도록 설계되어 있다.
#   JSP·nginx.conf·CloudWatch Agent JSON 은 따옴표와 중괄호가 많아
#   문서에 전문을 싣고 학생이 복사하면 반드시 어긋난다.
#   대신 값이 박히지 않았는지(플레이스홀더 유지) 5단계에서 검사한다.
# ============================================================
set -euo pipefail

DEST="${1:-}"
[ -n "$DEST" ] || { echo "사용법: bash publish-student.sh <학생저장소경로>"; exit 1; }
SRC="$(cd "$(dirname "$0")" && pwd)"

C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_0=$'\033[0m'
ok(){ printf '%s[✔]%s %s\n' "$C_G" "$C_0" "$*"; }
warn(){ printf '%s[!]%s %s\n' "$C_Y" "$C_0" "$*"; }
die(){ printf '%s[✘]%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

[ -d "$DEST/.git" ] || die "$DEST 는 git 저장소가 아닙니다. 먼저 clone 하십시오."
[ -d "$SRC/00-common" ] || die "$SRC 가 강사 저장소가 아닌 것 같습니다."

printf '\n원본: %s\n대상: %s\n\n' "$SRC" "$DEST"

# ---------- 1. 기존 배포본 비우기 (.git 은 보존) ----------
find "$DEST" -mindepth 1 -maxdepth 1 ! -name '.git' -exec rm -rf {} +
ok "대상 저장소 초기화 (.git 보존)"

# ---------- 2. 공통 계층 — 전량 복사 ----------
mkdir -p "$DEST/00-common"
cp "$SRC/00-common/"*.sh "$DEST/00-common/"
ok "00-common 5개 파일 복사"

# ---------- 3. 학생이 실행할 스크립트만 ----------
for f in preflight.sh verify-all.sh; do
  [ -f "$SRC/$f" ] && cp "$SRC/$f" "$DEST/"
done
ok "preflight.sh, verify-all.sh 복사"

# ---------- 4. 랩별 — verify / teardown 만 ----------
n=0
for d in "$SRC"/lab*/; do
  [ -d "$d" ] || continue
  lab="$(basename "$d")"
  mkdir -p "$DEST/$lab"
  # verify.sh  : 자기 채점
  # teardown.sh : 정리(비용 관리)
  # analyze.sh  : 로그 분석 — 읽기 전용이라 학생에게 주어도 안전하다
  for f in verify.sh teardown.sh analyze.sh loadtest.sh; do
    [ -f "$d/$f" ] && cp "$d/$f" "$DEST/$lab/"
  done
  # setup-*.sh : 따라하기형 문서가 sed 로 치환해 쓰는 구성 스크립트
  #              플레이스홀더 상태 그대로 내보낸다(값은 학생이 채운다)
  for f in "$d"setup-*.sh; do
    [ -f "$f" ] && cp "$f" "$DEST/$lab/"
  done
  n=$((n+1))
done
ok "랩 ${n}개의 verify / teardown / analyze / loadtest / setup 복사"

# ---------- 5. 유출 검사 ----------
leak=0
while IFS= read -r f; do
  warn "유출 의심 파일: ${f#$DEST/}"; leak=$((leak+1))
done < <(find "$DEST" \( -name 'build*.sh' -o -name 'repair.sh' -o -name 'mock-aws' \
           -o -name 'test-common.sh' -o -name 'publish-student.sh' \
           -o -name 'gen-diagram.py' -o -path '*/tools/*' \) 2>/dev/null)
[ "$leak" -eq 0 ] && ok "유출 검사 통과 — build/repair 계열 없음" \
                  || die "유출 파일 ${leak}건 — 스크립트를 점검하십시오"

# ---------- 5-2. setup-*.sh 값 박힘 검사 ----------
# setup 스크립트는 내보내되, 실제 계정번호·엔드포인트·시크릿이
# 치환된 채로 나가면 안 된다. 플레이스홀더가 살아 있는지 확인한다.
baked=0
while IFS= read -r f; do
  rel="${f#$DEST/}"
  # 플레이스홀더가 하나도 없으면 이미 치환된 파일이다
  if ! grep -qE '__[A-Z_]+__' "$f"; then
    warn "플레이스홀더 없음(치환된 파일 의심): $rel"; baked=$((baked+1))
  fi
  # 실제 값이 박혀 있으면 즉시 중단
  if grep -qE '[0-9]{12}|\.rds\.amazonaws\.com|fs-[0-9a-f]{8,}|vpce-[0-9a-f]{8,}' "$f"; then
    warn "실제 값 박힘: $rel"; baked=$((baked+1))
  fi
done < <(find "$DEST" -name 'setup-*.sh' 2>/dev/null)
[ "$baked" -eq 0 ] && ok "setup 스크립트 검사 통과 — 플레이스홀더 유지" \
                   || die "setup 스크립트 ${baked}건 이상 — 값이 박힌 채 나갑니다"

# ---------- 6. 학생용 부속 파일 ----------
cat > "$DEST/.gitattributes" << 'EOF'
* text=auto eol=lf
*.sh text eol=lf
EOF

cat > "$DEST/.gitignore" << 'EOF'
# 실행 중 생성되는 것 — 커밋하지 않는다
state/
*.bak
student.env
EOF

cat > "$DEST/student.env.example" << 'EOF'
# 이 파일을 student.env 로 복사한 뒤 강사가 배정한 값으로 채우십시오.
#   cp student.env.example student.env
export PREFIX=st00              # 강사 배정 (예: st01)
export STUDENT_BASE=11          # 강사 배정 (홀수, 학생마다 다름)
export REGION=ap-northeast-2
export STATE_SYNC=1
export STATE_BUCKET=            # 강사 배정 버킷 이름
EOF

cat > "$DEST/README.md" << 'EOF'
# 캡스톤 실습 — 학생용

AWS 콘솔과 CLI로 3계층 아키텍처를 13개 랩에 걸쳐 누적 구축합니다.
Lab 1에서 만든 것 위에 Lab 2를 얹고, 그 위에 Lab 3을 얹는 방식입니다.

## 시작하기

AWS 콘솔에 로그인한 뒤 리전이 **서울(ap-northeast-2)** 인지 확인하고 CloudShell을 엽니다.

```bash
git clone https://github.com/worldvit/capstone-labs.git
cd capstone-labs
chmod +x 00-common/*.sh *.sh lab*/*.sh
mkdir -p state

cp student.env.example student.env
vi student.env                    # 강사가 배정한 값 입력
echo '[ -f ~/capstone-labs/student.env ] && . ~/capstone-labs/student.env' >> ~/.bashrc
source student.env

bash preflight.sh
```

**명명 미리보기**의 접두사와 VPC 대역이 배정받은 값과 같은지 반드시 확인하십시오.

## 실습 진행

각 랩의 과제는 실습 문서를 따릅니다. 구축을 마치면 스스로 채점하십시오.

```bash
bash lab01-iam/verify.sh          # 해당 랩만 채점
bash verify-all.sh 5              # Lab 1~5 전체 진단
```

`PASS` / `FAIL`이 항목별로 나옵니다. `FAIL`이 뜨면 그 항목만 다시 구성하면 됩니다.

## 로그 분석

Lab 9 이후에는 수집된 로그를 직접 읽어 봅니다. 구축이 끝이 아니라 해석이 시작입니다.

```bash
bash lab09-observability/analyze.sh --list    # 분석 항목 보기
bash lab09-observability/analyze.sh           # 전체 실행
bash lab09-observability/analyze.sh 5         # 5번 항목만
MINUTES=360 bash lab09-observability/analyze.sh   # 기간 넓히기
```

각 항목은 "무엇을 묻는가 → 어떻게 묻는가 → 무엇을 읽어내는가" 순으로 나옵니다.
데이터가 비어 있으면 트래픽을 만든 뒤 3~5분 기다리십시오.

## 서버 구성 스크립트 (setup-*.sh)

일부 랩에는 `setup-` 로 시작하는 스크립트가 들어 있습니다.
Tomcat·nginx·CloudWatch Agent 설정처럼 따옴표와 중괄호가 많아
문서에 옮겨 적으면 반드시 어긋나는 것들입니다.

| 랩 | 스크립트 | 채워야 할 값 |
|---|---|---|
| lab08b-3tier | setup-tomcat.sh | 리전, DB 엔드포인트·포트·이름, 시크릿 ARN |
| lab08b-3tier | setup-nginx.sh | App 서버 업스트림 목록 |
| lab09-observability | setup-cwagent.sh | 로그 그룹 이름, 역할 |
| lab10-alb-asg | setup-app-node.sh | 위 항목 + EFS ID |

이 파일들은 `__DB_ENDPOINT__` 같은 **빈칸 상태로 배포**됩니다.
실습 문서가 안내하는 `sed` 명령으로 본인 계정의 값을 채워 쓰십시오.

```bash
# 어떤 빈칸이 있는지 먼저 봅니다
grep -oE '__[A-Z_]+__' lab08b-3tier/setup-tomcat.sh | sort -u

# 스크립트가 무엇을 하는지 읽어 봅니다 — 그대로 실행하지 마십시오
less lab08b-3tier/setup-tomcat.sh
```

**빈칸을 채우지 않고 실행하면 서버가 뜨지 않습니다.** 그것이 정상입니다.
어떤 값이 어디에 쓰이는지 이해하는 것이 이 랩의 목적입니다.

<!-- 강사 메모: 비밀번호는 스크립트에 넣지 않습니다. 시크릿 ARN 만 넣고
     애플리케이션이 실행 시점에 Secrets Manager 에서 직접 읽습니다. -->


## 다른 PC에서 이어하기

랩에서 만든 리소스 ID는 S3에 자동 백업됩니다.

```bash
bash 00-common/state-sync.sh pull
bash verify-all.sh
```

## 정리

과제 제출과 채점이 끝난 랩은 정리해 비용을 줄이십시오.

```bash
bash lab03-network/teardown.sh    # 특정 랩만
```

NAT 게이트웨이, Aurora, ALB는 켜두면 계속 과금됩니다.

## 주의

- `state/` 디렉터리는 직접 수정하지 마십시오. 랩 간 인계 정보가 들어 있습니다.
- 배정받은 `PREFIX`와 `STUDENT_BASE`를 임의로 바꾸면 다른 학생 리소스와 충돌합니다.
EOF
ok "README.md, .gitignore, .gitattributes, student.env.example 생성"

# ---------- 7. 결과 ----------
printf '\n%s생성된 파일%s\n' "$C_Y" "$C_0"
(cd "$DEST" && find . -path ./.git -prune -o -type f -print | sort | sed 's|^\./|  |')

printf '\n%s다음 단계%s\n' "$C_Y" "$C_0"
cat << NEXT
  cd $DEST
  git add -A
  git commit -m "Publish student distribution"
  git push
NEXT
