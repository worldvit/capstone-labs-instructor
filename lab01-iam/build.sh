#!/usr/bin/env bash
# Lab 1 — 계정 기반 + IAM 권한 체계
source "$(dirname "$0")/../00-common/bootstrap.sh"
guard
banner "Lab 1 build — IAM 권한 체계"
LAB=1

# ---------- 1. EC2 인스턴스 프로파일 역할 ----------
TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

if aws iam get-role --role-name "$N_ROLE_EC2" >/dev/null 2>&1; then
  skip "IAM 역할 $N_ROLE_EC2"
else
  aws iam create-role --role-name "$N_ROLE_EC2" \
    --assume-role-policy-document "$TRUST" \
    --description "capstone lab EC2 role" \
    --tags Key=Project,Value=capstone Key=Lab,Value=$LAB Key=Owner,Value="$PREFIX" >/dev/null
  ok "IAM 역할 생성: $N_ROLE_EC2"
fi

# SSM 접속용 + S3 읽기 + CloudWatch Agent (Lab 4·6·9에서 사용)
for P in AmazonSSMManagedInstanceCore AmazonS3ReadOnlyAccess CloudWatchAgentServerPolicy; do
  aws iam attach-role-policy --role-name "$N_ROLE_EC2" \
    --policy-arn "arn:aws:iam::aws:policy/$P" >/dev/null 2>&1 \
    && ok "정책 연결: $P" || skip "정책 $P"
done

if aws iam get-instance-profile --instance-profile-name "$N_PROFILE_EC2" >/dev/null 2>&1; then
  skip "인스턴스 프로파일 $N_PROFILE_EC2"
else
  aws iam create-instance-profile --instance-profile-name "$N_PROFILE_EC2" >/dev/null
  ok "인스턴스 프로파일 생성: $N_PROFILE_EC2"
fi

if aws iam get-instance-profile --instance-profile-name "$N_PROFILE_EC2" \
     --query 'InstanceProfile.Roles[0].RoleName' --output text 2>/dev/null | grep -q "^$N_ROLE_EC2$"; then
  skip "프로파일-역할 결합"
else
  aws iam add-role-to-instance-profile \
    --instance-profile-name "$N_PROFILE_EC2" --role-name "$N_ROLE_EC2" >/dev/null
  ok "프로파일에 역할 결합"
fi

save_state ROLE_EC2 "$N_ROLE_EC2"
save_state PROFILE_EC2 "$N_PROFILE_EC2"

# ---------- 2. 학생 그룹 ----------
add_group() { # 이름 정책ARN...
  local g="$1"; shift
  if aws iam get-group --group-name "$g" >/dev/null 2>&1; then
    skip "그룹 $g"
  else
    aws iam create-group --group-name "$g" >/dev/null
    ok "그룹 생성: $g"
  fi
  for arn in "$@"; do
    aws iam attach-group-policy --group-name "$g" --policy-arn "$arn" >/dev/null 2>&1 || true
  done
}
add_group "$N_GROUP_ADMIN"   arn:aws:iam::aws:policy/ReadOnlyAccess
add_group "$N_GROUP_NETWORK" arn:aws:iam::aws:policy/AmazonVPCFullAccess
add_group "$N_GROUP_APP"     arn:aws:iam::aws:policy/AmazonEC2ReadOnlyAccess

# ---------- 3. MFA 강제 정책 (그룹에 부착) ----------
MFA_POL="${PREFIX}-require-mfa"
MFA_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${MFA_POL}"
if aws iam get-policy --policy-arn "$MFA_ARN" >/dev/null 2>&1; then
  skip "정책 $MFA_POL"
else
  cat > /tmp/${PREFIX}-mfa.json << 'JSON'
{"Version":"2012-10-17","Statement":[
 {"Sid":"AllowSelfManage","Effect":"Allow",
  "Action":["iam:ChangePassword","iam:GetUser","iam:CreateVirtualMFADevice",
            "iam:EnableMFADevice","iam:ListMFADevices","iam:ResyncMFADevice"],
  "Resource":["arn:aws:iam::*:user/${aws:username}","arn:aws:iam::*:mfa/${aws:username}"]},
 {"Sid":"DenyAllWithoutMFA","Effect":"Deny","NotAction":
   ["iam:CreateVirtualMFADevice","iam:EnableMFADevice","iam:GetUser",
    "iam:ListMFADevices","iam:ListVirtualMFADevices","iam:ResyncMFADevice","sts:GetSessionToken"],
  "Resource":"*","Condition":{"BoolIfExists":{"aws:MultiFactorAuthPresent":"false"}}}]}
JSON
  aws iam create-policy --policy-name "$MFA_POL" \
    --policy-document file:///tmp/${PREFIX}-mfa.json >/dev/null
  ok "MFA 강제 정책 생성: $MFA_POL"
fi
for g in "$N_GROUP_ADMIN" "$N_GROUP_NETWORK" "$N_GROUP_APP"; do
  aws iam attach-group-policy --group-name "$g" --policy-arn "$MFA_ARN" >/dev/null 2>&1 || true
done
save_state MFA_POLICY_ARN "$MFA_ARN"

# ---------- 4. IAM 전파 대기 ----------
wait_until "인스턴스 프로파일 전파" 60 5 \
  aws iam get-instance-profile --instance-profile-name "$N_PROFILE_EC2" || true

save_state ACCOUNT_ID "$ACCOUNT_ID"
save_state LAB01_DONE 1
ok "Lab 1 완료"
