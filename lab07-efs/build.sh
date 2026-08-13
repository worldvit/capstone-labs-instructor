#!/usr/bin/env bash
# Lab 7 — EFS 파일 시스템 + AZ별 마운트 대상
source "$(dirname "$0")/../00-common/bootstrap.sh"
guard
banner "Lab 7 build — EFS 공유 스토리지"
LAB=7
need_state VPC_SVC SN_SVC_APP_A SN_SVC_APP_C SG_APP

# ---------- efs-sg ----------
SG_EFS_ID="$(_q aws ec2 describe-security-groups --filters "Name=group-name,Values=$N_SG_EFS" "Name=vpc-id,Values=$VPC_SVC" --query 'SecurityGroups[0].GroupId' --output text)"
if [ -z "$SG_EFS_ID" ]; then
  SG_EFS_ID="$(aws ec2 create-security-group --group-name "$N_SG_EFS" --description "capstone EFS" \
    --vpc-id "$VPC_SVC" --tag-specifications "$(tagspec security-group "$N_SG_EFS" $LAB)" \
    --query 'GroupId' --output text)"
  ok "SG 생성: $N_SG_EFS ($SG_EFS_ID)"
else skip "SG $N_SG_EFS ($SG_EFS_ID)"; fi
# 중복과 진짜 오류를 구분한다.
_e="$(aws ec2 authorize-security-group-ingress --group-id "$SG_EFS_ID" \
      --ip-permissions "IpProtocol=tcp,FromPort=2049,ToPort=2049,UserIdGroupPairs=[{GroupId=$SG_APP}]" 2>&1 >/dev/null)" \
  && ok "  NFS 2049 인바운드 from app-sg" \
  || case "$_e" in
       *InvalidPermission.Duplicate*) skip "  NFS 2049 인바운드" ;;
       *) err "  NFS 2049 인바운드 추가 실패"; printf '      %s\n' "$_e" >&2; exit 1 ;;
     esac
save_state SG_EFS "$SG_EFS_ID"

# ---------- 파일 시스템 ----------
FS="$(_q aws efs describe-file-systems --query "FileSystems[?Name=='$N_EFS'].FileSystemId | [0]" --output text)"
if [ -z "$FS" ]; then
  FS="$(aws efs create-file-system \
        --creation-token "${PREFIX}-efs-token" \
        --performance-mode generalPurpose --throughput-mode elastic --encrypted \
        --tags Key=Name,Value="$N_EFS" Key=Project,Value=capstone Key=Lab,Value=$LAB Key=Owner,Value="$PREFIX" \
        --query 'FileSystemId' --output text)"
  ok "EFS 생성: $N_EFS ($FS)"
else skip "EFS $N_EFS ($FS)"; fi
save_state EFS_ID "$FS"

wait_until "EFS available" 300 10 bash -c \
  "[ \"\$(aws efs describe-file-systems --file-system-id $FS --query 'FileSystems[0].LifeCycleState' --output text)\" = 'available' ]"

# ---------- 마운트 대상 (AZ별 1개) ----------
mk_mt() { # 서브넷ID
  local sn="$1" existing
  existing="$(_q aws efs describe-mount-targets --file-system-id "$FS" --query "MountTargets[?SubnetId=='$sn'].MountTargetId | [0]" --output text)"
  if [ -n "$existing" ]; then skip "  마운트 대상 $sn ($existing)"; return; fi
  aws efs create-mount-target --file-system-id "$FS" --subnet-id "$sn" \
    --security-groups "$SG_EFS_ID" --query 'MountTargetId' --output text >/dev/null
  ok "  마운트 대상 생성: $sn"
}
mk_mt "$SN_SVC_APP_A"
mk_mt "$SN_SVC_APP_C"

wait_until "마운트 대상 2개 available" 400 15 bash -c \
  "[ \"\$(aws efs describe-mount-targets --file-system-id $FS --query \"length(MountTargets[?LifeCycleState=='available'])\" --output text)\" = '2' ]"

# ---------- 수명 주기 정책 ----------
aws efs put-lifecycle-configuration --file-system-id "$FS" \
  --lifecycle-policies "TransitionToIA=AFTER_30_DAYS" "TransitionToPrimaryStorageClass=AFTER_1_ACCESS" >/dev/null 2>&1 \
  && ok "EFS 수명 주기 정책 적용" || warn "EFS 수명 주기 정책 적용 실패(무시 가능)"

# ---------- 액세스 포인트 ----------
AP="$(_q aws efs describe-access-points --file-system-id "$FS" --query 'AccessPoints[0].AccessPointId' --output text)"
if [ -z "$AP" ]; then
  AP="$(aws efs create-access-point --file-system-id "$FS" \
        --posix-user "Uid=1000,Gid=1000" \
        --root-directory "Path=/app,CreationInfo={OwnerUid=1000,OwnerGid=1000,Permissions=0755}" \
        --tags Key=Name,Value="${PREFIX}-efs-ap" Key=Project,Value=capstone Key=Owner,Value="$PREFIX" \
        --query 'AccessPointId' --output text)"
  ok "액세스 포인트 생성: $AP (/app)"
else skip "액세스 포인트 ($AP)"; fi
save_state EFS_AP "$AP"

# ---------- SSM으로 앱 서버에 마운트 ----------
if [ -n "${APP_A_ID:-}" ] && [ -n "${APP_C_ID:-}" ]; then
  log "SSM으로 앱 서버 2대에 EFS 마운트"
  CMD="$(aws ssm send-command --instance-ids "$APP_A_ID" "$APP_C_ID" \
    --document-name AWS-RunShellScript \
    --parameters "commands=[
      'dnf -y install amazon-efs-utils || true',
      'mkdir -p /mnt/efs',
      'grep -q \"$FS\" /etc/fstab || echo \"$FS:/ /mnt/efs efs _netdev,tls 0 0\" >> /etc/fstab',
      'mountpoint -q /mnt/efs || mount -t efs -o tls $FS:/ /mnt/efs || true',
      'mountpoint -q /mnt/efs || { dnf -y install nfs-utils; mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport $FS.efs.$REGION.amazonaws.com:/ /mnt/efs; }',
      'mountpoint -q /mnt/efs && df -hT /mnt/efs'
    ]" --query 'Command.CommandId' --output text 2>/dev/null || true)"
  if [ -n "$CMD" ]; then
    save_state EFS_MOUNT_CMD "$CMD"
    ok "SSM 명령 전송: $CMD"
    # 전송만 하고 넘어가면 verify가 InProgress 상태를 실패로 잡는다. 완료까지 기다린다.
    wait_until "EFS 마운트 완료" 180 10 bash -c \
      "s=\$(aws ssm list-command-invocations --command-id $CMD \
            --query 'CommandInvocations[].Status' --output text 2>/dev/null)
       case \"\$s\" in *InProgress*|*Pending*|'') exit 1 ;; *) exit 0 ;; esac" || true
    for iid in "$APP_A_ID" "$APP_C_ID"; do
      st="$(_q aws ssm list-command-invocations --command-id "$CMD" --instance-id "$iid" \
            --query 'CommandInvocations[0].Status' --output text)"
      case "$st" in
        Success) ok "  마운트 성공: $iid" ;;
        *) warn "  마운트 상태 $st: $iid"
           warn "    상세: aws ssm list-command-invocations --command-id $CMD --instance-id $iid --details" ;;
      esac
    done
  else
    warn "SSM 명령 전송 실패 — 수동 마운트가 필요합니다."
  fi
else
  warn "APP_A_ID/APP_C_ID 없음 — Lab 4를 먼저 실행하세요. 마운트를 건너뜁니다."
fi

save_state LAB07_DONE 1
ok "Lab 7 완료"
