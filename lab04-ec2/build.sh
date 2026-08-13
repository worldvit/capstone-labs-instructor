#!/usr/bin/env bash
# Lab 4 — Bastion + App 서버 2대 / SSH·SSM 접속 경로
source "$(dirname "$0")/../00-common/bootstrap.sh"
guard
banner "Lab 4 build — EC2 배치 및 접속 경로"
LAB=4
need_state VPC_SVC VPC_MGMT SN_MGMT_PUB_A SN_SVC_APP_A SN_SVC_APP_C SG_BASTION SG_APP PROFILE_EC2

AMI="$(latest_ami)"
ok "AMI 조회(SSM 파라미터): $AMI"
save_state AMI_ID "$AMI"

# ---------- 키 페어 ----------
if aws ec2 describe-key-pairs --key-names "$N_KEYPAIR" >/dev/null 2>&1; then
  skip "키 페어 $N_KEYPAIR"
else
  KEYDIR="$ROOT_DIR/state/keys"; mkdir -p "$KEYDIR"; chmod 700 "$KEYDIR"
  aws ec2 create-key-pair --key-name "$N_KEYPAIR" \
    --tag-specifications "$(tagspec key-pair "$N_KEYPAIR" $LAB)" \
    --query 'KeyMaterial' --output text > "$KEYDIR/${N_KEYPAIR}.pem"
  chmod 400 "$KEYDIR/${N_KEYPAIR}.pem"
  ok "키 페어 생성: $KEYDIR/${N_KEYPAIR}.pem"
fi
save_state KEYPAIR "$N_KEYPAIR"

# ---------- 사용자 데이터 ----------
UD_APP="$(base64 -w0 << 'EOF'
#!/bin/bash
dnf -y install httpd amazon-cloudwatch-agent
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
AZ=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone)
IID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
echo "<h1>capstone app</h1><p>AZ: $AZ</p><p>instance: $IID</p>" > /var/www/html/index.html
echo OK > /var/www/html/health
systemctl enable --now httpd
EOF
)"

mk_ec2() { # 이름 서브넷 SG 키 사용자데이터(b64|"")
  local name="$1" sn="$2" sg="$3" key="$4" ud="$5" id args
  id="$(instance_id_by_name "$name")"
  if [ -n "$id" ]; then skip "EC2 $name ($id)"; save_state "$key" "$id"; return; fi
  args=(--image-id "$AMI" --instance-type "$INSTANCE_TYPE" --subnet-id "$sn"
        --security-group-ids "$sg" --key-name "$N_KEYPAIR"
        --iam-instance-profile "Name=$N_PROFILE_EC2"
        --metadata-options "HttpTokens=required,HttpEndpoint=enabled"
        --tag-specifications "$(tagspec instance "$name" $LAB)")
  [ -n "$ud" ] && args+=(--user-data "$ud")
  id="$(aws ec2 run-instances "${args[@]}" --query 'Instances[0].InstanceId' --output text)"
  ok "EC2 생성: $name ($id)"
  save_state "$key" "$id"
}

mk_ec2 "$N_BASTION" "$SN_MGMT_PUB_A" "$SG_BASTION" BASTION_ID ""
mk_ec2 "$N_APP_A"   "$SN_SVC_APP_A"  "$SG_APP"     APP_A_ID "$UD_APP"
mk_ec2 "$N_APP_C"   "$SN_SVC_APP_C"  "$SG_APP"     APP_C_ID "$UD_APP"

log "인스턴스 running 대기"
aws ec2 wait instance-running --instance-ids "$BASTION_ID" "$APP_A_ID" "$APP_C_ID"
ok "3대 running"

# Bastion만 퍼블릭 IP 필요
aws ec2 modify-instance-attribute --instance-id "$BASTION_ID" --no-source-dest-check >/dev/null 2>&1 || true
BIP="$(_q aws ec2 describe-instances --instance-ids "$BASTION_ID" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
if [ -z "$BIP" ]; then
  ALLOC="$(eip_alloc_by_name "${N_BASTION}-eip")"
  [ -z "$ALLOC" ] && ALLOC="$(aws ec2 allocate-address --domain vpc \
      --tag-specifications "$(tagspec elastic-ip "${N_BASTION}-eip" $LAB)" --query AllocationId --output text)"
  aws ec2 associate-address --instance-id "$BASTION_ID" --allocation-id "$ALLOC" >/dev/null
  save_state BASTION_EIP "$ALLOC"
  BIP="$(_q aws ec2 describe-instances --instance-ids "$BASTION_ID" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
  ok "Bastion EIP 연결: $BIP"
fi
save_state BASTION_IP "$BIP"

# ---------- Regional NAT 확장 관찰 ----------
# App 서브넷에 ENI가 처음 생기는 시점이 여기다. Regional NAT는 이를 감지해 해당 AZ로 확장한다.
# 확장에는 최대 60분이 걸릴 수 있으나, 그동안에도 기존 AZ의 NAT를 통해 영역 간으로 처리되므로
# 통신은 끊기지 않는다. 아래는 관찰용 출력이다.
if [ "${NAT_MODE_USED:-$NAT_MODE}" = "regional" ]; then
  log "Regional NAT 확장 상태 (App 서브넷에 ENI가 방금 생성됨)"
  rnat_az_status "${NAT_SVC_A:-}"  "서비스 VPC RNAT"
  rnat_az_status "${NAT_MGMT_A:-}" "관리 VPC RNAT"
  log "  새 AZ 확장은 최대 60분 소요. 그 전까지는 기존 AZ를 경유해 처리됩니다."
fi

log "SSM 등록 대기 (Lab 5의 인터페이스 엔드포인트 이전에는 NAT 경유로 등록됨)"
wait_until "SSM 관리형 인스턴스 등록" 420 15 bash -c \
  "[ \"\$(aws ssm describe-instance-information --filters Key=InstanceIds,Values=$APP_A_ID --query 'length(InstanceInformationList)' --output text)\" = '1' ]" || {
  warn "SSM 등록이 확인되지 않았습니다. 다음을 점검하세요."
  warn "  1) 인스턴스 프로파일 $N_PROFILE_EC2 연결 여부"
  warn "  2) App 라우팅 테이블의 0.0.0.0/0 → NAT 경로"
  warn "  3) NAT 게이트웨이 상태 (regional 모드는 위 커버 AZ 출력 참고)"
  warn "  잠시 후 bash lab04-ec2/verify.sh 로 재확인하십시오."
}

save_state LAB04_DONE 1
ok "Lab 4 완료 — Bastion $BIP / App 2대"
