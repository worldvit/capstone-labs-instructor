#!/usr/bin/env bash
# Lab 8 — 관리형 데이터베이스 다중 AZ 구성
#
#   DB_MODE=rds     (기본) 일반 RDS 다중 AZ 배포 — Free Tier 계정에서도 VPC 안에 생성 가능
#   DB_MODE=aurora         Aurora 클러스터(라이터+리더) — 유료 플랜 필요
#
# Free Tier 계정은 Aurora에 세 가지 제약이 있다.
#   1) 백업 보존 1일까지  2) aurora-postgresql 만  3) WithExpressConfiguration 필수
# 3번은 클러스터를 VPC 밖에 만들기 때문에 이 캡스톤 아키텍처와 양립하지 않는다.
source "$(dirname "$0")/../00-common/bootstrap.sh"
guard
banner "Lab 8 build — 데이터베이스 다중 AZ ($DB_MODE 모드)"
LAB=8
need_state SN_SVC_DB_A SN_SVC_DB_C SG_DB

db_port_for() {
  case "$1" in
    postgres|aurora-postgresql) echo 5432 ;;
    *)                          echo 3306 ;;
  esac
}

# Lab 3은 3306만 열어 두었다. PostgreSQL이면 5432가 필요하다.
ensure_db_port() {
  local port="$1" e
  [ -n "${SG_DB:-}" ] && [ -n "${SG_APP:-}" ] || { warn "SG_DB/SG_APP 없음 — 포트 규칙 생략"; return 0; }
  e="$(aws ec2 authorize-security-group-ingress --group-id "$SG_DB" \
        --ip-permissions "IpProtocol=tcp,FromPort=$port,ToPort=$port,UserIdGroupPairs=[{GroupId=$SG_APP}]" 2>&1 >/dev/null)" \
    && { ok "db-sg에 ${port} 인바운드 추가 (from app-sg)"; return 0; }
  case "$e" in
    *InvalidPermission.Duplicate*) skip "db-sg ${port} 인바운드"; return 0 ;;
    *) err "db-sg ${port} 인바운드 추가 실패"; printf '      %s\n' "$e" >&2; return 1 ;;
  esac
}

# ---------- 1. DB 서브넷 그룹 ----------
if aws rds describe-db-subnet-groups --db-subnet-group-name "$N_DB_SUBNET_GROUP" >/dev/null 2>&1; then
  skip "DB 서브넷 그룹 $N_DB_SUBNET_GROUP"
else
  aws rds create-db-subnet-group --db-subnet-group-name "$N_DB_SUBNET_GROUP" \
    --db-subnet-group-description "capstone db subnets" \
    --subnet-ids "$SN_SVC_DB_A" "$SN_SVC_DB_C" \
    --tags Key=Project,Value=capstone Key=Lab,Value=$LAB Key=Owner,Value="$PREFIX" >/dev/null
  ok "DB 서브넷 그룹 생성 (2개 AZ)"
fi

# ============================================================
# RDS 다중 AZ 배포
# ============================================================
if [ "$DB_MODE" = "rds" ]; then
  DB_PORT="$(db_port_for "$RDS_ENGINE")"
  ensure_db_port "$DB_PORT"

  if aws rds describe-db-instances --db-instance-identifier "$N_RDS" >/dev/null 2>&1; then
    skip "RDS 인스턴스 $N_RDS"
  else
    RETAIN="$DB_BACKUP_RETENTION"; MULTIAZ=1
    mk_rds() { # <보존일수> <다중AZ 1|0>
      local retain="$1" maz="$2"
      local A=(--db-instance-identifier "$N_RDS"
               --engine "$RDS_ENGINE"
               --db-instance-class "$RDS_INSTANCE_CLASS"
               --allocated-storage "$RDS_STORAGE_GB"
               --storage-type gp3
               --master-username capstoneadmin
               --manage-master-user-password
               --db-subnet-group-name "$N_DB_SUBNET_GROUP"
               --vpc-security-group-ids "$SG_DB"
               --no-publicly-accessible
               --storage-encrypted
               --backup-retention-period "$retain"
               --preferred-backup-window "17:00-17:30"
               --auto-minor-version-upgrade
               --tags "Key=Name,Value=$N_RDS" "Key=Project,Value=capstone" "Key=Lab,Value=$LAB" "Key=Owner,Value=$PREFIX")
      # --multi-az : 다른 AZ에 대기 인스턴스를 두고 동기 복제한다.
      #              장애 시 자동 승격되며 엔드포인트 주소는 바뀌지 않는다.
      if [ "$maz" = "1" ]; then A+=(--multi-az); else A+=(--no-multi-az); fi
      # shellcheck disable=SC2069  # 의도적: stdout은 버리고 stderr만 캡처한다
      aws rds create-db-instance "${A[@]}" 2>&1 >/dev/null
    }

    for attempt in 1 2 3; do
      if ERR="$(mk_rds "$RETAIN" "$MULTIAZ")"; then
        ok "RDS 인스턴스 생성 요청: $N_RDS"
        log "  엔진 $RDS_ENGINE / 클래스 $RDS_INSTANCE_CLASS / 다중 AZ $([ "$MULTIAZ" = 1 ] && echo 예 || echo 아니오) / 백업 ${RETAIN}일"
        break
      fi
      case "$ERR" in
        *"backup retention period exceeds"*|*BackupRetention*)
          warn "Free Tier — 백업 보존 ${RETAIN}일 거부. 1일로 재시도합니다."
          RETAIN=1 ;;
        *MultiAZ*|*"multi-az"*|*"Multi-AZ"*|*"multi az"*)
          warn "Free Tier — 다중 AZ 거부. 단일 AZ로 재시도합니다."
          warn "  고가용성 실습은 강사 시연으로 대체하십시오."
          MULTIAZ=0 ;;
        *)
          err "RDS 인스턴스 생성 실패"; printf '      %s\n' "$ERR" >&2; exit 1 ;;
      esac
      [ "$attempt" = 3 ] && { err "3회 시도 후에도 실패"; printf '      %s\n' "$ERR" >&2; exit 1; }
    done
    save_state DB_RETAIN_USED "$RETAIN"
    save_state DB_MULTIAZ_USED "$MULTIAZ"
  fi

  log "RDS available 대기 (10~15분 소요)"
  log "  진행 확인: aws rds describe-db-instances --db-instance-identifier $N_RDS --query 'DBInstances[0].DBInstanceStatus' --output text"
  aws rds wait db-instance-available --db-instance-identifier "$N_RDS"
  ok "RDS available"

  EP="$(_q  aws rds describe-db-instances --db-instance-identifier "$N_RDS" --query 'DBInstances[0].Endpoint.Address' --output text)"
  PORT="$(_q aws rds describe-db-instances --db-instance-identifier "$N_RDS" --query 'DBInstances[0].Endpoint.Port' --output text)"
  SEC="$(_q aws rds describe-db-instances --db-instance-identifier "$N_RDS" --query 'DBInstances[0].MasterUserSecret.SecretArn' --output text)"
  AZP="$(_q aws rds describe-db-instances --db-instance-identifier "$N_RDS" --query 'DBInstances[0].AvailabilityZone' --output text)"
  AZS="$(_q aws rds describe-db-instances --db-instance-identifier "$N_RDS" --query 'DBInstances[0].SecondaryAvailabilityZone' --output text)"

  save_state DB_IDENTIFIER   "$N_RDS"
  save_state DB_ENDPOINT     "$EP"
  save_state DB_PORT_USED    "${PORT:-$DB_PORT}"
  save_state DB_SECRET_ARN   "$SEC"
  save_state DB_ENGINE_USED  "$RDS_ENGINE"
  save_state DB_MODE_USED    "rds"
  # verify와 이후 랩이 공통으로 참조하도록 별칭도 저장한다.
  save_state AURORA_WRITER_EP "$EP"

  ok "엔드포인트 : $EP:${PORT:-$DB_PORT}"
  ok "기본 AZ    : ${AZP:-확인불가}"
  ok "대기 AZ    : ${AZS:-없음(단일 AZ)}"
  ok "자격 증명  : ${SEC:-없음}"

# ============================================================
# Aurora 클러스터 (유료 플랜)
# ============================================================
else
  DB_INSTANCE_CLASS="${DB_INSTANCE_CLASS:-db.t4g.medium}"
  DB_PORT="$(db_port_for "$DB_ENGINE")"
  ensure_db_port "$DB_PORT"

  if aws rds describe-db-clusters --db-cluster-identifier "$N_AURORA_CLUSTER" >/dev/null 2>&1; then
    skip "Aurora 클러스터 $N_AURORA_CLUSTER"
  else
    mk_cluster() { # <보존일수> <엔진>
      local retain="$1" eng="$2"
      local logs=(error slowquery)
      [ "$eng" = "aurora-postgresql" ] && logs=(postgresql)
      local A=(--db-cluster-identifier "$N_AURORA_CLUSTER"
               --engine "$eng" --master-username capstoneadmin --manage-master-user-password
               --db-subnet-group-name "$N_DB_SUBNET_GROUP" --vpc-security-group-ids "$SG_DB"
               --backup-retention-period "$retain" --preferred-backup-window "17:00-17:30"
               --storage-encrypted --enable-cloudwatch-logs-exports "${logs[@]}"
               --tags "Key=Name,Value=$N_AURORA_CLUSTER" "Key=Project,Value=capstone" "Key=Lab,Value=$LAB" "Key=Owner,Value=$PREFIX")
      [ -n "$DB_ENGINE_VERSION" ] && A+=(--engine-version "$DB_ENGINE_VERSION")
      # shellcheck disable=SC2069  # 의도적: stdout은 버리고 stderr만 캡처한다
      aws rds create-db-cluster "${A[@]}" 2>&1 >/dev/null
    }
    RETAIN="$DB_BACKUP_RETENTION"; ENG="$DB_ENGINE"
    for attempt in 1 2 3; do
      if ERR="$(mk_cluster "$RETAIN" "$ENG")"; then
        ok "Aurora 클러스터 생성 요청 (엔진 $ENG / 보존 ${RETAIN}일)"; break
      fi
      case "$ERR" in
        *"backup retention period exceeds"*) warn "보존 ${RETAIN}일 거부 → 1일"; RETAIN=1 ;;
        *"cluster engine type is not available"*) warn "$ENG 불가 → aurora-postgresql"; ENG=aurora-postgresql ;;
        *WithExpressConfiguration*)
          err "Free Tier 계정은 Aurora를 VPC 안에 만들 수 없습니다."
          err "  Express 구성 클러스터는 사용자 VPC에 속하지 않아 db-sg를 적용할 수 없습니다."
          err "  DB_MODE=rds 로 실행하거나 계정 플랜을 업그레이드하십시오."
          exit 1 ;;
        *) err "클러스터 생성 실패"; printf '      %s\n' "$ERR" >&2; exit 1 ;;
      esac
      [ "$attempt" = 3 ] && { err "3회 시도 후 실패"; printf '      %s\n' "$ERR" >&2; exit 1; }
    done
    save_state DB_RETAIN_USED "$RETAIN"
    save_state DB_ENGINE_USED "$ENG"
  fi

  mk_db_instance() { # <식별자> <AZ>
    local id="$1" az="$2"
    aws rds describe-db-instances --db-instance-identifier "$id" >/dev/null 2>&1 && { skip "DB 인스턴스 $id"; return 0; }
    aws rds create-db-instance --db-instance-identifier "$id" \
      --db-cluster-identifier "$N_AURORA_CLUSTER" --engine "${DB_ENGINE_USED:-$DB_ENGINE}" \
      --db-instance-class "$DB_INSTANCE_CLASS" --availability-zone "$az" --no-publicly-accessible \
      --tags "Key=Name,Value=$id" "Key=Project,Value=capstone" "Key=Lab,Value=$LAB" "Key=Owner,Value=$PREFIX" >/dev/null
    ok "DB 인스턴스 생성 요청: $id @$az"
  }
  mk_db_instance "$N_AURORA_WRITER" "$AZ_A"
  mk_db_instance "$N_AURORA_READER" "$AZ_C"

  log "DB 인스턴스 available 대기 (10~15분)"
  aws rds wait db-instance-available --db-instance-identifier "$N_AURORA_WRITER"
  aws rds wait db-instance-available --db-instance-identifier "$N_AURORA_READER"
  ok "라이터·리더 available"

  save_state AURORA_CLUSTER   "$N_AURORA_CLUSTER"
  save_state AURORA_WRITER_EP "$(_q aws rds describe-db-clusters --db-cluster-identifier "$N_AURORA_CLUSTER" --query 'DBClusters[0].Endpoint' --output text)"
  save_state AURORA_READER_EP "$(_q aws rds describe-db-clusters --db-cluster-identifier "$N_AURORA_CLUSTER" --query 'DBClusters[0].ReaderEndpoint' --output text)"
  save_state DB_SECRET_ARN    "$(_q aws rds describe-db-clusters --db-cluster-identifier "$N_AURORA_CLUSTER" --query 'DBClusters[0].MasterUserSecret.SecretArn' --output text)"
  save_state DB_PORT_USED "$DB_PORT"
  save_state DB_MODE_USED "aurora"
  ok "라이터: ${AURORA_WRITER_EP:-}"
  ok "리더  : ${AURORA_READER_EP:-}"
fi

save_state LAB08_DONE 1
ok "Lab 8 완료"
