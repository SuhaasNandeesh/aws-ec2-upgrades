#!/usr/bin/env bash
set -euo pipefail

# test/teardown-test-infra.sh
# Tears down the test environment created by setup-test-infra.sh.
# Discovers resources by tags (Name=ec2-patch-test*) so no state file needed.
#
# Usage:
#   AWS_PROFILE=root ./test/teardown-test-infra.sh

PROFILE="${AWS_PROFILE:-root}"
REGION="us-east-1"
BUCKET_NAME="ssm-test-transfer-126007213837"

echo "=== EC2 Patch Automation — Test Infra Teardown ==="
echo "Profile: $PROFILE"
echo "Region:  $REGION"
echo ""

# ---------------------------------------------------------------------------
# 1. Find and terminate the EC2 instance
# ---------------------------------------------------------------------------
echo "[1/8] Finding test EC2 instances..."
INSTANCE_IDS=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=ec2-patch-test" "Name=instance-state-name,Values=running,pending,shutting-down,stopped" \
  --region "$REGION" \
  --profile "$PROFILE" \
  --query 'Reservations[].Instances[].InstanceId' \
  --output text 2>/dev/null || echo "")

if [[ -n "$INSTANCE_IDS" ]]; then
  # Convert tab-separated output to space-separated for AWS CLI
  INSTANCE_IDS=$(echo "$INSTANCE_IDS" | tr '\t' ' ')
  echo "  Terminating instances: $INSTANCE_IDS"
  aws ec2 terminate-instances --instance-ids $INSTANCE_IDS \
    --region "$REGION" --profile "$PROFILE" >/dev/null
  echo "  Waiting for instances to terminate..."
  aws ec2 wait instance-terminated --instance-ids $INSTANCE_IDS \
    --region "$REGION" --profile "$PROFILE"
  echo "  Instances terminated."
else
  echo "  No running test instances found."
fi

# ---------------------------------------------------------------------------
# 2. Delete S3 bucket
# ---------------------------------------------------------------------------
echo "[2/8] Deleting S3 bucket $BUCKET_NAME..."
if aws s3api head-bucket --bucket "$BUCKET_NAME" --region "$REGION" --profile "$PROFILE" 2>/dev/null; then
  aws s3 rm "s3://$BUCKET_NAME" --recursive --region "$REGION" --profile "$PROFILE" 2>/dev/null || true
  aws s3api delete-bucket --bucket "$BUCKET_NAME" --region "$REGION" --profile "$PROFILE" >/dev/null
  echo "  Bucket deleted."
else
  echo "  Bucket not found."
fi

# ---------------------------------------------------------------------------
# 3. Delete IAM instance profile + role
# ---------------------------------------------------------------------------
echo "[3/8] Deleting IAM instance profile..."
if aws iam get-instance-profile --instance-profile-name EC2-SSM-Patch-Profile --profile "$PROFILE" 2>/dev/null; then
  # Remove role from profile first
  aws iam remove-role-from-instance-profile \
    --instance-profile-name EC2-SSM-Patch-Profile \
    --role-name EC2-SSM-Patch-Role \
    --profile "$PROFILE" >/dev/null 2>&1 || true
  aws iam delete-instance-profile \
    --instance-profile-name EC2-SSM-Patch-Profile \
    --profile "$PROFILE" >/dev/null 2>&1
  echo "  Instance profile deleted."
else
  echo "  Instance profile not found."
fi

echo "[4/8] Deleting IAM role..."
if aws iam get-role --role-name EC2-SSM-Patch-Role --profile "$PROFILE" 2>/dev/null; then
  # Detach managed policies
  aws iam detach-role-policy \
    --role-name EC2-SSM-Patch-Role \
    --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore \
    --profile "$PROFILE" >/dev/null 2>&1 || true
  aws iam delete-role --role-name EC2-SSM-Patch-Role \
    --profile "$PROFILE" >/dev/null 2>&1
  echo "  Role deleted."
else
  echo "  Role not found."
fi

# ---------------------------------------------------------------------------
# 5. Find and delete security group
# ---------------------------------------------------------------------------
echo "[5/8] Deleting security group..."
SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=ec2-patch-test-sg" \
  --region "$REGION" \
  --profile "$PROFILE" \
  --query 'SecurityGroups[0].GroupId' \
  --output text 2>/dev/null || echo "")

if [[ -n "$SG_ID" && "$SG_ID" != "None" ]]; then
  # Wait a moment for ENI to release after instance termination
  sleep 5
  aws ec2 delete-security-group --group-id "$SG_ID" \
    --region "$REGION" --profile "$PROFILE" >/dev/null 2>&1 && echo "  SG deleted: $SG_ID" || echo "  SG not found or still in use."
else
  echo "  Security group not found."
fi

# ---------------------------------------------------------------------------
# 6. Find and delete route table associations + route table
# ---------------------------------------------------------------------------
echo "[6/8] Deleting route table..."
RT_ID=$(aws ec2 describe-route-tables \
  --filters "Name=tag:Name,Values=ec2-patch-test-rt" \
  --region "$REGION" \
  --profile "$PROFILE" \
  --query 'RouteTables[0].RouteTableId' \
  --output text 2>/dev/null || echo "")

if [[ -n "$RT_ID" && "$RT_ID" != "None" ]]; then
  # Disassociate all associations
  ASSOC_IDS=$(aws ec2 describe-route-tables \
    --route-table-ids "$RT_ID" \
    --region "$REGION" \
    --profile "$PROFILE" \
    --query 'RouteTables[0].Associations[].RouteTableAssociationId' \
    --output text 2>/dev/null || echo "")
  for AID in $ASSOC_IDS; do
    aws ec2 disassociate-route-table --association-id "$AID" \
      --region "$REGION" --profile "$PROFILE" >/dev/null 2>&1 || true
  done
  aws ec2 delete-route-table --route-table-id "$RT_ID" \
    --region "$REGION" --profile "$PROFILE" >/dev/null 2>&1 && echo "  Route table deleted: $RT_ID" || echo "  Route table not found."
else
  echo "  Route table not found."
fi

# ---------------------------------------------------------------------------
# 7. Detach and delete IGW
# ---------------------------------------------------------------------------
echo "[7/8] Deleting Internet Gateway..."
IGW_ID=$(aws ec2 describe-internet-gateways \
  --filters "Name=tag:Name,Values=ec2-patch-test-igw" \
  --region "$REGION" \
  --profile "$PROFILE" \
  --query 'InternetGateways[0].InternetGatewayId' \
  --output text 2>/dev/null || echo "")

if [[ -n "$IGW_ID" && "$IGW_ID" != "None" ]]; then
  VPC_ID=$(aws ec2 describe-internet-gateways \
    --internet-gateway-ids "$IGW_ID" \
    --region "$REGION" \
    --profile "$PROFILE" \
    --query 'InternetGateways[0].Attachments[0].VpcId' \
    --output text 2>/dev/null || echo "")
  if [[ -n "$VPC_ID" && "$VPC_ID" != "None" ]]; then
    aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" \
      --region "$REGION" --profile "$PROFILE" >/dev/null 2>&1 || true
  fi
  aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID" \
    --region "$REGION" --profile "$PROFILE" >/dev/null 2>&1 && echo "  IGW deleted: $IGW_ID" || echo "  IGW not found."
else
  echo "  Internet Gateway not found."
fi

# ---------------------------------------------------------------------------
# 8. Delete subnet + VPC
# ---------------------------------------------------------------------------
echo "[8/8] Deleting subnet and VPC..."
SUBNET_ID=$(aws ec2 describe-subnets \
  --filters "Name=tag:Name,Values=ec2-patch-test-public" \
  --region "$REGION" \
  --profile "$PROFILE" \
  --query 'Subnets[0].SubnetId' \
  --output text 2>/dev/null || echo "")

if [[ -n "$SUBNET_ID" && "$SUBNET_ID" != "None" ]]; then
  aws ec2 delete-subnet --subnet-id "$SUBNET_ID" \
    --region "$REGION" --profile "$PROFILE" >/dev/null 2>&1 && echo "  Subnet deleted: $SUBNET_ID" || echo "  Subnet not found."
else
  echo "  Subnet not found."
fi

VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=ec2-patch-test" \
  --region "$REGION" \
  --profile "$PROFILE" \
  --query 'Vpcs[0].VpcId' \
  --output text 2>/dev/null || echo "")

if [[ -n "$VPC_ID" && "$VPC_ID" != "None" ]]; then
  aws ec2 delete-vpc --vpc-id "$VPC_ID" \
    --region "$REGION" --profile "$PROFILE" >/dev/null 2>&1 && echo "  VPC deleted: $VPC_ID" || echo "  VPC deletion failed (may have dependencies)."
else
  echo "  VPC not found."
fi

echo ""
echo "========================================"
echo "=== Teardown Complete ==="
echo "========================================"