#!/usr/bin/env bash
# Lab 3 — IGW / AZ별 NAT / 라우팅 계층 분리 / SG 체인 / NACL
source "$(dirname "$0")/../00-common/bootstrap.sh"
guard
banner "Lab 3 build — 인터넷 경로 + 계층 보안 경계"
LAB=3
need_state VPC_SVC VPC_MGMT SN_SVC_PUB_A SN_MGMT_PUB_A

# ---------- 1. IGW ----------
mk_igw() { # 이름 VPC_ID 키
  local name="$1" vpc="$2" key="$3" id
  id="$(igw_id_by_name "$name")"
  if [ -z "$id" ]; then
    id="$(aws ec2 create-internet-gateway \
          --tag-specifications "$(tagspec internet-gateway "$name" $LAB)" \
          --query 'InternetGateway.InternetGatewayId' --output text)"
    ok "IGW 생성: $name ($id)"
  else skip "IGW $name ($id)"; fi
  aws ec2 attach-internet-gateway --internet-gateway-id "$id" --vpc-id "$vpc" >/dev/null 2>&1 \
    && ok "IGW 연결 → $vpc" || skip "IGW 연결"
  save_state "$key" "$id"
}
mk_igw "$N_IGW_SVC"  "$VPC_SVC"  IGW_SVC
mk_igw "$N_IGW_MGMT" "$VPC_MGMT" IGW_MGMT

# ---------- 2. NAT 게이트웨이 ----------
# NAT_MODE=regional : VPC당 1개. 모든 AZ로 자동 확장. 퍼블릭 서브넷·EIP 불필요.
# NAT_MODE=zonal    : AZ당 1개. 퍼블릭 서브넷에 배치하고 EIP를 직접 할당.
log "NAT 방식: $NAT_MODE"

if [ "$NAT_MODE" = "regional" ]; then
  # CLI가 이 기능을 지원하는지 먼저 확인한다(2025-11 출시).
  aws ec2 create-nat-gateway help 2>/dev/null | grep -q -- '--availability-mode' \
    || aws ec2 create-nat-gateway --generate-cli-skeleton 2>/dev/null | grep -q 'AvailabilityMode' \
    || warn "이 AWS CLI가 --availability-mode를 지원하지 않을 수 있습니다. 실패 시 NAT_MODE=zonal 로 실행하십시오."

  mk_rnat() { # 이름 VPC_ID 키
    local name="$1" vpc="$2" key="$3" id e
    id="$(natgw_id_by_name "$name")"
    if [ -n "$id" ]; then skip "Regional NAT $name ($id)"; save_state "$key" "$id"; return 0; fi
    e="$(aws ec2 create-nat-gateway --availability-mode regional --vpc-id "$vpc" \
          --tag-specifications "$(tagspec natgateway "$name" $LAB)" \
          --query 'NatGateway.NatGatewayId' --output text 2>&1)" \
      || { err "Regional NAT 생성 실패: $name"; printf '      %s\n' "$e" >&2
           err "  CLI가 미지원이면 NAT_MODE=zonal bash lab03-network/build.sh 로 실행하십시오."; return 1; }
    id="$e"
    ok "Regional NAT 생성 요청: $name ($id) — VPC 전체 자동 확장"
    save_state "$key" "$id"
  }
  mk_rnat "${PREFIX}-rnat-svc"  "$VPC_SVC"  NAT_SVC_A
  mk_rnat "${PREFIX}-rnat-mgmt" "$VPC_MGMT" NAT_MGMT_A
  # 같은 NAT ID를 두 AZ가 공유한다. 라우팅 단계에서 동일 ID를 참조하기 위해 별칭을 둔다.
  save_state NAT_SVC_C  "$NAT_SVC_A"
  save_state NAT_MGMT_C "$NAT_MGMT_A"
  NAT_LIST="$NAT_SVC_A $NAT_MGMT_A"
else
  mk_nat() { # 이름 퍼블릭서브넷ID 키
    local name="$1" sn="$2" key="$3" id alloc
    id="$(natgw_id_by_name "$name")"
    if [ -n "$id" ]; then skip "NAT $name ($id)"; save_state "$key" "$id"; return 0; fi
    alloc="$(eip_alloc_by_name "${name}-eip")"
    if [ -z "$alloc" ]; then
      alloc="$(aws ec2 allocate-address --domain vpc \
               --tag-specifications "$(tagspec elastic-ip "${name}-eip" $LAB)" \
               --query 'AllocationId' --output text)"
      ok "EIP 할당: ${name}-eip ($alloc)"
    fi
    id="$(aws ec2 create-nat-gateway --subnet-id "$sn" --allocation-id "$alloc" \
          --tag-specifications "$(tagspec natgateway "$name" $LAB)" \
          --query 'NatGateway.NatGatewayId' --output text)"
    ok "NAT 생성 요청: $name ($id)"
    save_state "$key" "$id"
    save_state "${key}_EIP" "$alloc"
  }
  mk_nat "${PREFIX}-nat-svc-a"  "$SN_SVC_PUB_A"  NAT_SVC_A
  mk_nat "${PREFIX}-nat-svc-c"  "$SN_SVC_PUB_C"  NAT_SVC_C
  mk_nat "${PREFIX}-nat-mgmt-a" "$SN_MGMT_PUB_A" NAT_MGMT_A
  mk_nat "${PREFIX}-nat-mgmt-c" "$SN_MGMT_PUB_C" NAT_MGMT_C
  NAT_LIST="$NAT_SVC_A $NAT_SVC_C $NAT_MGMT_A $NAT_MGMT_C"
fi
save_state NAT_MODE_USED "$NAT_MODE"

log "NAT 게이트웨이 available 대기 (수 분 소요)"
for n in $NAT_LIST; do
  aws ec2 wait nat-gateway-available --nat-gateway-ids "$n" && ok "NAT available: $n"
done

# ---------- 3. 라우팅 테이블 ----------
mk_rt() { # 이름 VPC_ID 키
  local name="$1" vpc="$2" key="$3" id
  id="$(rt_id_by_name "$name")"
  if [ -z "$id" ]; then
    id="$(aws ec2 create-route-table --vpc-id "$vpc" \
          --tag-specifications "$(tagspec route-table "$name" $LAB)" \
          --query 'RouteTable.RouteTableId' --output text)"
    ok "라우팅 테이블 생성: $name ($id)"
  else skip "라우팅 테이블 $name ($id)"; fi
  save_state "$key" "$id"
}
route_igw() { aws ec2 create-route --route-table-id "$1" --destination-cidr-block 0.0.0.0/0 --gateway-id "$2" >/dev/null 2>&1 \
              && ok "  기본 경로 → IGW" || skip "  기본 경로"; }
route_nat() { aws ec2 create-route --route-table-id "$1" --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$2" >/dev/null 2>&1 \
              && ok "  기본 경로 → NAT" || skip "  기본 경로"; }
assoc() { aws ec2 associate-route-table --route-table-id "$1" --subnet-id "$2" >/dev/null 2>&1 \
          && ok "  연결 $2" || skip "  연결 $2"; }

mk_rt "${PREFIX}-rt-svc-pub"   "$VPC_SVC"  RT_SVC_PUB
route_igw "$RT_SVC_PUB" "$IGW_SVC"; assoc "$RT_SVC_PUB" "$SN_SVC_PUB_A"; assoc "$RT_SVC_PUB" "$SN_SVC_PUB_C"

mk_rt "${PREFIX}-rt-svc-app-a" "$VPC_SVC"  RT_SVC_APP_A
route_nat "$RT_SVC_APP_A" "$NAT_SVC_A"; assoc "$RT_SVC_APP_A" "$SN_SVC_APP_A"

mk_rt "${PREFIX}-rt-svc-app-c" "$VPC_SVC"  RT_SVC_APP_C
route_nat "$RT_SVC_APP_C" "$NAT_SVC_C"; assoc "$RT_SVC_APP_C" "$SN_SVC_APP_C"

mk_rt "${PREFIX}-rt-svc-db"    "$VPC_SVC"  RT_SVC_DB
assoc "$RT_SVC_DB" "$SN_SVC_DB_A"; assoc "$RT_SVC_DB" "$SN_SVC_DB_C"   # 외부 경로 없음(의도)

mk_rt "${PREFIX}-rt-mgmt-pub"   "$VPC_MGMT" RT_MGMT_PUB
route_igw "$RT_MGMT_PUB" "$IGW_MGMT"; assoc "$RT_MGMT_PUB" "$SN_MGMT_PUB_A"; assoc "$RT_MGMT_PUB" "$SN_MGMT_PUB_C"

mk_rt "${PREFIX}-rt-mgmt-app-a" "$VPC_MGMT" RT_MGMT_APP_A
route_nat "$RT_MGMT_APP_A" "$NAT_MGMT_A"; assoc "$RT_MGMT_APP_A" "$SN_MGMT_APP_A"

mk_rt "${PREFIX}-rt-mgmt-app-c" "$VPC_MGMT" RT_MGMT_APP_C
route_nat "$RT_MGMT_APP_C" "$NAT_MGMT_C"; assoc "$RT_MGMT_APP_C" "$SN_MGMT_APP_C"

mk_rt "${PREFIX}-rt-mgmt-db"    "$VPC_MGMT" RT_MGMT_DB
assoc "$RT_MGMT_DB" "$SN_MGMT_DB_A"; assoc "$RT_MGMT_DB" "$SN_MGMT_DB_C"

# ---------- 4. 보안 그룹 체인 ----------
mk_sg() { # 이름 설명 VPC_ID 키
  local name="$1" desc="$2" vpc="$3" key="$4" id
  id="$(_q aws ec2 describe-security-groups --filters "Name=group-name,Values=$name" "Name=vpc-id,Values=$vpc" --query 'SecurityGroups[0].GroupId' --output text)"
  if [ -z "$id" ]; then
    id="$(aws ec2 create-security-group --group-name "$name" --description "$desc" --vpc-id "$vpc" \
          --tag-specifications "$(tagspec security-group "$name" $LAB)" --query 'GroupId' --output text)"
    ok "SG 생성: $name ($id)"
  else skip "SG $name ($id)"; fi
  save_state "$key" "$id"
}
# 중복(Duplicate)과 진짜 오류를 구분한다. 구분하지 않으면 실패가 '이미 존재'로 위장된다.
_authz() { # _authz <설명> <group-id> <ip-permissions>
  local desc="$1" gid="$2" perm="$3" e
  e="$(aws ec2 authorize-security-group-ingress --group-id "$gid" --ip-permissions "$perm" 2>&1 >/dev/null)" \
    && { ok "  $desc"; return 0; }
  case "$e" in
    *InvalidPermission.Duplicate*) skip "  $desc"; return 0 ;;
    *) err "  $desc — 실패"; printf '      %s\n' "$e" >&2; return 1 ;;
  esac
}
ing_cidr() { _authz "인바운드 $2/$3 from $4" "$1" "IpProtocol=$2,FromPort=$3,ToPort=$3,IpRanges=[{CidrIp=$4}]"; }
ing_sg()   { _authz "인바운드 $2/$3 from SG $4" "$1" "IpProtocol=$2,FromPort=$3,ToPort=$3,UserIdGroupPairs=[{GroupId=$4}]"; }

mk_sg "$N_SG_BASTION" "capstone bastion"    "$VPC_MGMT" SG_BASTION
mk_sg "$N_SG_ALB"     "capstone ALB"        "$VPC_SVC"  SG_ALB
mk_sg "$N_SG_APP"     "capstone app tier"   "$VPC_SVC"  SG_APP
mk_sg "$N_SG_DB"      "capstone db tier"    "$VPC_SVC"  SG_DB
mk_sg "$N_SG_VPCE"    "capstone vpc endpoint" "$VPC_SVC" SG_VPCE

# Bastion: 강사 지정 CIDR에서만 SSH. 미지정 시 규칙을 만들지 않는다(0.0.0.0/0 금지)
if [ -n "${ADMIN_CIDR:-}" ]; then
  ing_cidr "$SG_BASTION" tcp 22 "$ADMIN_CIDR"
else
  warn "ADMIN_CIDR 미지정 — Bastion SSH 인바운드를 생성하지 않았습니다."
  warn "  예: ADMIN_CIDR=\"\$(curl -s https://checkip.amazonaws.com)/32\" bash lab03-network/build.sh"
fi
ing_cidr "$SG_ALB" tcp 80  0.0.0.0/0
ing_cidr "$SG_ALB" tcp 443 0.0.0.0/0
ing_sg   "$SG_APP" tcp 80   "$SG_ALB"
# Bastion은 다른 VPC(관리 VPC)에 있다. 이 시점에는 두 VPC를 잇는 경로가 없어
# 교차 VPC SG 참조를 만들 수 없으므로 CIDR로 허용한다.
# Lab 5에서 TGW에 보안 그룹 참조 지원을 켠 뒤 SG 참조로 전환한다.
ing_cidr "$SG_APP" tcp 22   "$VPC_MGMT_CIDR"
ing_sg   "$SG_DB"  tcp 3306 "$SG_APP"
ing_cidr "$SG_VPCE" tcp 443 "$VPC_SVC_CIDR"

# ---------- 5. NACL (App 계층 2차 방어선) ----------
NACL_NAME="${PREFIX}-nacl-svc-app"
NACL="$(_q aws ec2 describe-network-acls --filters "Name=tag:Name,Values=$NACL_NAME" --query 'NetworkAcls[0].NetworkAclId' --output text)"
if [ -z "$NACL" ]; then
  NACL="$(aws ec2 create-network-acl --vpc-id "$VPC_SVC" \
          --tag-specifications "$(tagspec network-acl "$NACL_NAME" $LAB)" \
          --query 'NetworkAcl.NetworkAclId' --output text)"
  ok "NACL 생성: $NACL_NAME ($NACL)"
else skip "NACL $NACL_NAME ($NACL)"; fi
nacl_rule() { aws ec2 create-network-acl-entry --network-acl-id "$NACL" --rule-number "$1" \
    --protocol "$2" --rule-action "$3" --cidr-block "$4" ${5:+--port-range From=$5,To=$6} $7 >/dev/null 2>&1 || true; }
nacl_rule 100 6  allow "$VPC_SVC_CIDR" 80   80   ""
nacl_rule 110 6  allow "$VPC_SVC_CIDR" 22   22   ""
nacl_rule 120 6  allow 0.0.0.0/0       1024 65535 ""       # 반환 트래픽 (상태 비저장 특성)
nacl_rule 100 6  allow 0.0.0.0/0       1    65535 "--egress"
save_state NACL_SVC_APP "$NACL"

save_state LAB03_DONE 1
ok "Lab 3 완료"
