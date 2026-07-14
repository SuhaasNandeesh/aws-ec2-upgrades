#!/usr/bin/env bash
set -euo pipefail

# test/setup-test-infra.sh
# Provisions a minimal test environment for EC2 patch automation:
#   - VPC + public subnet + IGW + route table
#   - Security group (no inbound, all outbound — SSM is outbound-only)
#   - IAM role + instance profile with AmazonSSMManagedInstanceCore
#   - S3 bucket for SSM connection plugin file transfer
#   - 1 EC2 instance (Ubuntu 22.04 LTS, t3.micro) with SSM agent
#
# No SSH key required — all access is via SSM Session Manager.
#
# Usage:
#   AWS_PROFILE=root ./test/setup-test-infra.sh
#
# Outputs the instance ID, S3 bucket name, and next steps at the end.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

PROFILE="${AWS_PROFILE:-root}"
REGION="us-east-1"
INSTANCE_TYPE="t3.micro"
BUCKET_NAME="ssm-test-transfer-126007213837"

echo "=== EC2 Patch Automation — Test Infra Setup ==="
echo "Profile: $PROFILE"
echo "Region:  $REGION"
echo ""

# ---------------------------------------------------------------------------
# 1. Resolve latest Ubuntu 22.04 LTS AMI (Canonical account 099720109477)
# ---------------------------------------------------------------------------
echo "[1/12] Resolving latest Ubuntu 22.04 LTS AMI..."
AMI_ID=$(aws ec2 describe-images \
  --owners 099720109477 \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" "Name=state,Values=available" \
  --region "$REGION" \
  --profile "$PROFILE" \
  --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
  --output text)
echo "  AMI: $AMI_ID"

# ---------------------------------------------------------------------------
# 2. Create VPC
# ---------------------------------------------------------------------------
echo "[2/12] Creating VPC..."
VPC_ID=$(aws ec2 create-vpc \
  --cidr-block 10.0.0.0/16 \
  --region "$REGION" \
  --profile "$PROFILE" \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=ec2-patch-test},{Key=Purpose,Value=patch-automation-test}]" \
  --query 'Vpc.VpcId' \
  --output text)
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames \
  --region "$REGION" --profile "$PROFILE" >/dev/null
echo "  VPC: $VPC_ID"

# ---------------------------------------------------------------------------
# 3. Create public subnet
# ---------------------------------------------------------------------------
echo "[3/12] Creating public subnet..."
SUBNET_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block 10.0.1.0/24 \
  --availability-zone us-east-1a \
  --region "$REGION" \
  --profile "$PROFILE" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=ec2-patch-test-public}]" \
  --query 'Subnet.SubnetId' \
  --output text)
aws ec2 modify-subnet-attribute --subnet-id "$SUBNET_ID" --map-public-ip-on-launch \
  --region "$REGION" --profile "$PROFILE" >/dev/null
echo "  Subnet: $SUBNET_ID"

# ---------------------------------------------------------------------------
# 4. Create + attach IGW
# ---------------------------------------------------------------------------
echo "[4/12] Creating Internet Gateway..."
IGW_ID=$(aws ec2 create-internet-gateway \
  --region "$REGION" \
  --profile "$PROFILE" \
  --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=ec2-patch-test-igw}]" \
  --query 'InternetGateway.InternetGatewayId' \
  --output text)
aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" \
  --region "$REGION" --profile "$PROFILE" >/dev/null
echo "  IGW: $IGW_ID"

# ---------------------------------------------------------------------------
# 5. Create route table + default route + associate
# ---------------------------------------------------------------------------
echo "[5/12] Creating route table..."
RT_ID=$(aws ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --region "$REGION" \
  --profile "$PROFILE" \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=ec2-patch-test-rt}]" \
  --query 'RouteTable.RouteTableId' \
  --output text)
aws ec2 create-route --route-table-id "$RT_ID" --destination-cidr-block 0.0.0.0/0 \
  --gateway-id "$IGW_ID" \
  --region "$REGION" --profile "$PROFILE" >/dev/null
aws ec2 associate-route-table --route-table-id "$RT_ID" --subnet-id "$SUBNET_ID" \
  --region "$REGION" --profile "$PROFILE" >/dev/null
echo "  Route table: $RT_ID"

# ---------------------------------------------------------------------------
# 6. Create security group (no inbound, all outbound)
# ---------------------------------------------------------------------------
echo "[6/12] Creating security group..."
SG_ID=$(aws ec2 create-security-group \
  --group-name ec2-patch-test-sg \
  --description "Security group for EC2 patch automation test (SSM only, no SSH)" \
  --vpc-id "$VPC_ID" \
  --region "$REGION" \
  --profile "$PROFILE" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=ec2-patch-test-sg}]" \
  --query 'GroupId' \
  --output text)
echo "  SG: $SG_ID"

# ---------------------------------------------------------------------------
# 7. Create IAM role for SSM
# ---------------------------------------------------------------------------
echo "[7/12] Creating IAM role EC2-SSM-Patch-Role..."
aws iam create-role \
  --role-name EC2-SSM-Patch-Role \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
  --profile "$PROFILE" >/dev/null 2>&1 || echo "  (role already exists, reusing)"
aws iam attach-role-policy \
  --role-name EC2-SSM-Patch-Role \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore \
  --profile "$PROFILE" >/dev/null 2>&1 || true
echo "  Role: EC2-SSM-Patch-Role"

# ---------------------------------------------------------------------------
# 8. Create IAM instance profile
# ---------------------------------------------------------------------------
echo "[8/12] Creating IAM instance profile EC2-SSM-Patch-Profile..."
aws iam create-instance-profile \
  --instance-profile-name EC2-SSM-Patch-Profile \
  --profile "$PROFILE" >/dev/null 2>&1 || echo "  (profile already exists, reusing)"
# Add role to profile (may already be added)
aws iam add-role-to-instance-profile \
  --instance-profile-name EC2-SSM-Patch-Profile \
  --role-name EC2-SSM-Patch-Role \
  --profile "$PROFILE" >/dev/null 2>&1 || true
echo "  Profile: EC2-SSM-Patch-Profile"

# Wait for instance profile to be ready
echo "  Waiting for instance profile to propagate..."
sleep 10

# ---------------------------------------------------------------------------
# 9. Create S3 bucket for SSM file transfer
# ---------------------------------------------------------------------------
echo "[9/12] Creating S3 bucket $BUCKET_NAME..."
aws s3api create-bucket \
  --bucket "$BUCKET_NAME" \
  --region "$REGION" \
  --profile "$PROFILE" >/dev/null 2>&1 || echo "  (bucket already exists, reusing)"
echo "  Bucket: $BUCKET_NAME"

# ---------------------------------------------------------------------------
# 10. Launch EC2 instance
# ---------------------------------------------------------------------------
echo "[10/12] Launching EC2 instance (Ubuntu 22.04, t3.micro)..."
INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE" \
  --subnet-id "$SUBNET_ID" \
  --security-group-ids "$SG_ID" \
  --iam-instance-profile "Name=EC2-SSM-Patch-Profile" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=ec2-patch-test},{Key=Purpose,Value=patch-automation-test}]" \
  --region "$REGION" \
  --profile "$PROFILE" \
  --query 'Instances[0].InstanceId' \
  --output text)
echo "  Instance: $INSTANCE_ID"

# ---------------------------------------------------------------------------
# 11. Wait for instance to be running
# ---------------------------------------------------------------------------
echo "[11/12] Waiting for instance to be running..."
aws ec2 wait instance-running \
  --instance-ids "$INSTANCE_ID" \
  --region "$REGION" \
  --profile "$PROFILE"
echo "  Instance is running."

# ---------------------------------------------------------------------------
# 12. Wait for SSM agent registration
# ---------------------------------------------------------------------------
echo "[12/12] Waiting for SSM agent to register (this can take 2-5 minutes)..."
SSM_READY=""
for i in $(seq 1 20); do
  SSM_RESULT=$(aws ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
    --region "$REGION" \
    --profile "$PROFILE" \
    --query 'InstanceInformationList[0].InstanceId' \
    --output text 2>/dev/null || echo "")
  if [[ -n "$SSM_RESULT" && "$SSM_RESULT" != "None" ]]; then
    SSM_READY="true"
    echo "  SSM agent registered!"
    break
  fi
  echo "  Attempt $i/20 — waiting 15s..."
  sleep 15
done

if [[ -z "$SSM_READY" ]]; then
  echo "ERROR: SSM agent did not register within 5 minutes."
  echo "Instance ID: $INSTANCE_ID (you can check manually or terminate via teardown script)"
  exit 1
fi

# ---------------------------------------------------------------------------
# Done — print summary
# ---------------------------------------------------------------------------
echo ""
echo "========================================"
echo "=== Test Infra Ready ==="
echo "========================================"
echo ""
echo "Instance ID:  $INSTANCE_ID"
echo "S3 bucket:    $BUCKET_NAME"
echo "Region:       $REGION"
echo "Profile:      $PROFILE"
echo "VPC ID:       $VPC_ID"
echo ""
echo "--- Next steps ---"
echo ""
echo "1. Add instance to inventory:"
echo "   cp inventory/targets.yml.example inventory/targets.yml"
echo "   # Then edit inventory/targets.yml and add under prod:"
echo "   prod:"
echo "     hosts:"
echo "       $INSTANCE_ID:"
echo ""
echo "2. Configure group_vars:"
echo "   cp inventory/group_vars/prod.yml.example inventory/group_vars/prod.yml"
echo "   # Then edit inventory/group_vars/prod.yml:"
echo "   aws_profile: $PROFILE"
echo "   aws_region: $REGION"
echo "   ssm_bucket_name: $BUCKET_NAME"
echo ""
echo "3. Install Ansible collections (if not done):"
echo "   ansible-galaxy collection install -r requirements.yml"
echo ""
echo "4. Fabricate inspector manifest:"
echo "   ./test/fabricate-manifest.sh"
echo ""
echo "5. Run tests:"
echo "   # Test A — Inspector-driven mode"
echo "   AWS_PROFILE=$PROFILE ./run-patch.sh --inspector-manifest inspector/manifest.json --no-snapshot"
echo ""
echo "   # Test B — Full dist-upgrade mode"
echo "   AWS_PROFILE=$PROFILE ./run-patch.sh --full-upgrade --no-snapshot"
echo ""
echo "6. Verify reports:"
echo "   ls reports/\$(date +%Y-%m-%d)/prod/"
echo ""
echo "7. Teardown when done:"
echo "   AWS_PROFILE=$PROFILE ./test/teardown-test-infra.sh"
echo ""