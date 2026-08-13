#!/usr/bin/env bash
# Lab 5 — S3 Gateway Endpoint / SSM Interface Endpoint / Transit Gateway
source "$(dirname "$0")/../00-common/bootstrap.sh"
guard
banner "Lab 5 build — VPC Endpoint + Transit Gateway"
LAB=5
need_state VPC_SVC VPC_MGMT RT_SVC_APP_A RT_SVC_APP_C RT_SVC_DB SN_SVC_APP_A SN_SVC_APP_C SG_VPCE

# ---------- 1. S3 Gateway Endpoint (PrivateLink 아님) ----------
NAME_S3E="${PREFIX}-vpce-s3"
S3E="$(vpce_id_by_name "$NAME_S3E")"
if [ -z "$S3E" ]; then
  S3E="$(aws ec2 create-vpc-endpoint --vpc-id "$VPC_SVC" \
        --vpc-endpoint-type Gateway \
        --service-name "com.amazonaws.${REGION}.s3" \
        --route-table-ids "$RT_SVC_APP_A" "$RT_SVC_APP_C" "$RT_SVC_DB" \
        --tag-specifications "$(tagspec vpc-endpoint "$NAME_S3E" $LAB)" \
        --query 'VpcEndpoint.VpcEndpointId' --output text)"
  ok "S3 Gateway Endpoint 생성: $S3E (App/DB 라우팅 테이블 연결)"
else skip "S3 Gateway Endpoint ($S3E)"; fi
save_state VPCE_S3 "$S3E"

# ---------- 2. SSM Interface Endpoint 3종 (PrivateLink) ----------
mk_iface_vpce() { # 서비스약칭 키
  local svc="$1" key="$2" name id
  name="${PREFIX}-vpce-${svc}"
  id="$(vpce_id_by_name "$name")"
  if [ -z "$id" ]; then
    id="$(aws ec2 create-vpc-endpoint --vpc-id "$VPC_SVC" \
          --vpc-endpoint-type Interface \
          --service-name "com.amazonaws.${REGION}.${svc}" \
          --subnet-ids "$SN_SVC_APP_A" "$SN_SVC_APP_C" \
          --security-group-ids "$SG_VPCE" \
          --private-dns-enabled \
          --tag-specifications "$(tagspec vpc-endpoint "$name" $LAB)" \
          --query 'VpcEndpoint.VpcEndpointId' --output text)"
    ok "Interface Endpoint 생성: $svc ($id)"
  else skip "Interface Endpoint $svc ($id)"; fi
  save_state "$key" "$id"
}
mk_iface_vpce ssm         VPCE_SSM
mk_iface_vpce ssmmessages VPCE_SSMMSG
mk_iface_vpce ec2messages VPCE_EC2MSG

wait_until "Interface Endpoint available" 300 15 bash -c \
  "[ \"\$(aws ec2 describe-vpc-endpoints --vpc-endpoint-ids $VPCE_SSM $VPCE_SSMMSG $VPCE_EC2MSG --query \"length(VpcEndpoints[?State=='available'])\" --output text)\" = '3' ]" || \
  warn "엔드포인트 available 확인 실패 — 콘솔에서 상태를 확인하세요."

# 참고: Regional NAT 게이트웨이의 라우팅 테이블은 Transit Gateway를 유효한 대상으로 지원한다.
# 이 랩에서 TGW를 세운 뒤에도 NAT 경유 아웃바운드는 그대로 동작한다.
if [ "${NAT_MODE_USED:-$NAT_MODE}" = "regional" ]; then
  log "NAT 방식: regional — 엔드포인트 생성 후에도 NAT 경유 경로는 유지됩니다."
fi

# ---------- 3. Transit Gateway ----------
TGW="$(tgw_id_by_name "$N_TGW")"
if [ -z "$TGW" ]; then
  TGW="$(aws ec2 create-transit-gateway --description "capstone TGW" \
        --options "DefaultRouteTableAssociation=enable,DefaultRouteTablePropagation=enable,DnsSupport=enable,SecurityGroupReferencingSupport=enable" \
        --tag-specifications "$(tagspec transit-gateway "$N_TGW" $LAB)" \
        --query 'TransitGateway.TransitGatewayId' --output text)"
  ok "TGW 생성: $TGW"
else skip "TGW ($TGW)"; fi
save_state TGW_ID "$TGW"

wait_until "TGW available" 600 20 bash -c \
  "[ \"\$(aws ec2 describe-transit-gateways --transit-gateway-ids $TGW --query 'TransitGateways[0].State' --output text)\" = 'available' ]"

mk_attach() { # VPC_ID 서브넷A 서브넷C 이름 키
  local vpc="$1" sa="$2" sc="$3" name="$4" key="$5" id
  id="$(tgw_attach_by_vpc "$vpc")"
  if [ -z "$id" ]; then
    id="$(aws ec2 create-transit-gateway-vpc-attachment \
          --transit-gateway-id "$TGW" --vpc-id "$vpc" --subnet-ids "$sa" "$sc" \
          --tag-specifications "$(tagspec transit-gateway-attachment "$name" $LAB)" \
          --query 'TransitGatewayVpcAttachment.TransitGatewayAttachmentId' --output text)"
    ok "TGW 어태치먼트 생성: $name ($id)"
  else skip "TGW 어태치먼트 $name ($id)"; fi
  save_state "$key" "$id"
}
mk_attach "$VPC_SVC"  "$SN_SVC_APP_A"  "$SN_SVC_APP_C"  "${PREFIX}-tgwatt-svc"  TGW_ATT_SVC
mk_attach "$VPC_MGMT" "$SN_MGMT_APP_A" "$SN_MGMT_APP_C" "${PREFIX}-tgwatt-mgmt" TGW_ATT_MGMT

wait_until "TGW 어태치먼트 available" 600 20 bash -c \
  "[ \"\$(aws ec2 describe-transit-gateway-attachments --transit-gateway-attachment-ids $TGW_ATT_SVC $TGW_ATT_MGMT --query \"length(TransitGatewayAttachments[?State=='available'])\" --output text)\" = '2' ]"

# ---------- 4. VPC 측 라우팅에 상대 VPC 경로 추가 ----------
# 중복과 진짜 오류를 구분한다. 구분하지 않으면 실패가 '이미 존재'로 위장된다.
add_tgw_route() {
  local e
  e="$(aws ec2 create-route --route-table-id "$1" --destination-cidr-block "$2" \
        --transit-gateway-id "$TGW" 2>&1 >/dev/null)" \
    && { ok "  경로 추가 $1 → $2 via TGW"; return 0; }
  case "$e" in
    *RouteAlreadyExists*) skip "  경로 $1 → $2"; return 0 ;;
    *) err "  경로 추가 실패 $1 → $2"; printf '      %s\n' "$e" >&2; return 1 ;;
  esac
}
for rt in "$RT_SVC_APP_A" "$RT_SVC_APP_C" "$RT_SVC_DB"; do add_tgw_route "$rt" "$VPC_MGMT_CIDR"; done
for rt in "${RT_MGMT_PUB:-}" "${RT_MGMT_APP_A:-}" "${RT_MGMT_APP_C:-}"; do
  [ -n "$rt" ] && add_tgw_route "$rt" "$VPC_SVC_CIDR" || true
done

# ---------- 5. 교차 VPC 보안 그룹 참조로 전환 ----------
# TGW 수준의 SecurityGroupReferencingSupport는 기본이 비활성이다. 기존 TGW라면 켜 준다.
SGR="$(_q aws ec2 describe-transit-gateways --transit-gateway-ids "$TGW" \
        --query 'TransitGateways[0].Options.SecurityGroupReferencingSupport' --output text)"
if [ "$SGR" != "enable" ]; then
  aws ec2 modify-transit-gateway --transit-gateway-id "$TGW" \
    --options "SecurityGroupReferencingSupport=enable" >/dev/null 2>&1 \
    && ok "TGW 보안 그룹 참조 지원 활성화" || warn "TGW SG 참조 지원 활성화 실패"
  wait_until "TGW 설정 반영" 300 15 bash -c \
    "[ \"\$(aws ec2 describe-transit-gateways --transit-gateway-ids $TGW --query 'TransitGateways[0].State' --output text)\" = 'available' ]" || true
else
  skip "TGW 보안 그룹 참조 지원"
fi

if [ -n "${SG_APP:-}" ] && [ -n "${SG_BASTION:-}" ]; then
  # Lab 3에서 CIDR로 열어 둔 22번을 SG 참조로 교체한다.
  e="$(aws ec2 authorize-security-group-ingress --group-id "$SG_APP" \
        --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,UserIdGroupPairs=[{GroupId=$SG_BASTION}]" 2>&1 >/dev/null)" \
    && ok "app-sg 22를 bastion-sg 참조로 추가" \
    || case "$e" in
         *Duplicate*) skip "app-sg 22 SG 참조" ;;
         *) warn "SG 참조 추가 실패 — CIDR 규칙을 유지합니다"; printf '      %s\n' "$e" >&2 ;;
       esac
  if [ "${DROP_CIDR_SSH:-0}" = "1" ]; then
    aws ec2 revoke-security-group-ingress --group-id "$SG_APP" \
      --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=$VPC_MGMT_CIDR}]" >/dev/null 2>&1 \
      && ok "CIDR 기반 22번 규칙 제거 (SG 참조만 유지)" || true
  else
    log "DROP_CIDR_SSH=1 로 실행하면 CIDR 규칙을 제거하고 SG 참조만 남깁니다."
  fi
fi

# ---------- 6. 경로 전환 확인 안내 ----------
banner "확인해 볼 것"
cat << 'GUIDE'
  1) 엔드포인트 경유 확인 — App 서버에서 NAT 없이 S3·SSM에 닿는지
       aws ssm start-session --target <APP_A_ID>
       # 세션 안에서
       aws s3 ls
       nslookup ssm.ap-northeast-2.amazonaws.com     # 프라이빗 IP가 나오면 엔드포인트 경유

  2) NAT와 엔드포인트의 역할 구분
       S3·SSM 트래픽 → VPC 엔드포인트 (인터넷 경유 안 함)
       그 외 아웃바운드(dnf update 등) → NAT 게이트웨이

  3) SG 참조 전환 결과
       aws ec2 describe-security-groups --group-ids <SG_APP> \
         --query "SecurityGroups[0].IpPermissions[?FromPort==\`22\`]"
       CIDR 규칙과 SG 참조 규칙이 함께 보입니다.
       DROP_CIDR_SSH=1 로 재실행하면 CIDR 규칙이 제거됩니다.
GUIDE

save_state LAB05_DONE 1
ok "Lab 5 완료 — Bastion에서 TGW 경유로 App 서버 접속 가능"
