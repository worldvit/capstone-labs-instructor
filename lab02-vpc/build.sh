#!/usr/bin/env bash
# Lab 2 — 멀티 VPC + 멀티 AZ 3계층 서브넷
source "$(dirname "$0")/../00-common/bootstrap.sh"
guard
banner "Lab 2 build — VPC 2개 / 서브넷 12개"
LAB=2

mk_vpc() { # 이름 CIDR 상태키
  local name="$1" cidr="$2" key="$3" id
  id="$(vpc_id_by_name "$name")"
  if [ -n "$id" ]; then skip "VPC $name ($id)"
  else
    id="$(aws ec2 create-vpc --cidr-block "$cidr" \
          --tag-specifications "$(tagspec vpc "$name" $LAB)" \
          --query 'Vpc.VpcId' --output text)"
    aws ec2 modify-vpc-attribute --vpc-id "$id" --enable-dns-support >/dev/null
    aws ec2 modify-vpc-attribute --vpc-id "$id" --enable-dns-hostnames >/dev/null
    ok "VPC 생성: $name ($id) $cidr"
  fi
  save_state "$key" "$id"
}

mk_subnet() { # 이름 VPC_ID CIDR AZ 상태키
  local name="$1" vpc="$2" cidr="$3" az="$4" key="$5" id
  id="$(subnet_id_by_name "$name")"
  if [ -n "$id" ]; then skip "서브넷 $name ($id)"
  else
    id="$(aws ec2 create-subnet --vpc-id "$vpc" --cidr-block "$cidr" \
          --availability-zone "$az" \
          --tag-specifications "$(tagspec subnet "$name" $LAB)" \
          --query 'Subnet.SubnetId' --output text)"
    ok "서브넷 생성: $name ($id) $cidr @$az"
  fi
  save_state "$key" "$id"
}

mk_vpc "$N_VPC_SVC"  "$VPC_SVC_CIDR"  VPC_SVC
mk_vpc "$N_VPC_MGMT" "$VPC_MGMT_CIDR" VPC_MGMT

# 서비스 VPC — 3계층 × 2 AZ
mk_subnet "${PREFIX}-svc-pub-a" "$VPC_SVC" "$SN_SVC_PUB_A_CIDR" "$AZ_A" SN_SVC_PUB_A
mk_subnet "${PREFIX}-svc-pub-c" "$VPC_SVC" "$SN_SVC_PUB_C_CIDR" "$AZ_C" SN_SVC_PUB_C
mk_subnet "${PREFIX}-svc-app-a" "$VPC_SVC" "$SN_SVC_APP_A_CIDR" "$AZ_A" SN_SVC_APP_A
mk_subnet "${PREFIX}-svc-app-c" "$VPC_SVC" "$SN_SVC_APP_C_CIDR" "$AZ_C" SN_SVC_APP_C
mk_subnet "${PREFIX}-svc-db-a"  "$VPC_SVC" "$SN_SVC_DB_A_CIDR"  "$AZ_A" SN_SVC_DB_A
mk_subnet "${PREFIX}-svc-db-c"  "$VPC_SVC" "$SN_SVC_DB_C_CIDR"  "$AZ_C" SN_SVC_DB_C

# 관리 VPC
mk_subnet "${PREFIX}-mgmt-pub-a" "$VPC_MGMT" "$SN_MGMT_PUB_A_CIDR" "$AZ_A" SN_MGMT_PUB_A
mk_subnet "${PREFIX}-mgmt-pub-c" "$VPC_MGMT" "$SN_MGMT_PUB_C_CIDR" "$AZ_C" SN_MGMT_PUB_C
mk_subnet "${PREFIX}-mgmt-app-a" "$VPC_MGMT" "$SN_MGMT_APP_A_CIDR" "$AZ_A" SN_MGMT_APP_A
mk_subnet "${PREFIX}-mgmt-app-c" "$VPC_MGMT" "$SN_MGMT_APP_C_CIDR" "$AZ_C" SN_MGMT_APP_C
mk_subnet "${PREFIX}-mgmt-db-a"  "$VPC_MGMT" "$SN_MGMT_DB_A_CIDR"  "$AZ_A" SN_MGMT_DB_A
mk_subnet "${PREFIX}-mgmt-db-c"  "$VPC_MGMT" "$SN_MGMT_DB_C_CIDR"  "$AZ_C" SN_MGMT_DB_C

save_state LAB02_DONE 1
ok "Lab 2 완료 — VPC 2 / 서브넷 12"
