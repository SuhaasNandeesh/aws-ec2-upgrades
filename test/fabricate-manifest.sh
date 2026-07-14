#!/usr/bin/env bash
set -euo pipefail

# test/fabricate-manifest.sh
# Queries the test EC2 instance via SSM for packages that have updates available,
# picks 2-3 of them, and writes inspector/manifest.json with the instance ID + those packages.
#
# This creates a "fabricated" inspector manifest that mimics what you'd get from
# an Inspector v2 export — but uses real upgradable packages so the upgrade
# actually changes package versions (a true end-to-end test).
#
# Usage:
#   AWS_PROFILE=root ./test/fabricate-manifest.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

PROFILE="${AWS_PROFILE:-root}"
REGION="us-east-1"

# Find the test instance by tag
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=ec2-patch-test" "Name=instance-state-name,Values=running" \
  --region "$REGION" \
  --profile "$PROFILE" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text)

if [[ -z "$INSTANCE_ID" || "$INSTANCE_ID" == "None" ]]; then
  echo "ERROR: No running instance with tag 'ec2-patch-test' found."
  echo "Run ./test/setup-test-infra.sh first."
  exit 1
fi

echo "=== Fabricating Inspector Manifest ==="
echo "Instance: $INSTANCE_ID"
echo ""

# Run apt-get update first, then list upgradable packages via SSM
echo "Running apt-get update on instance..."
UPDATE_CMD_ID=$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["DEBIAN_FRONTEND=noninteractive apt-get update -qq"]' \
  --region "$REGION" \
  --profile "$PROFILE" \
  --query 'Command.CommandId' \
  --output text)

# Wait for apt-get update to complete
for i in $(seq 1 12); do
  STATUS=$(aws ssm get-command-invocation \
    --command-id "$UPDATE_CMD_ID" \
    --instance-id "$INSTANCE_ID" \
    --region "$REGION" \
    --profile "$PROFILE" \
    --query 'Status' \
    --output text 2>/dev/null || echo "InProgress")
  if [[ "$STATUS" == "Success" ]]; then
    break
  elif [[ "$STATUS" == "Failed" || "$STATUS" == "TimedOut" || "$STATUS" == "Cancelled" ]]; then
    echo "WARNING: apt-get update command status: $STATUS (continuing anyway)"
    break
  fi
  sleep 5
done

echo "Querying upgradable packages..."
COMMAND_ID=$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["apt list --upgradable 2>/dev/null | tail -n +2 | cut -d/ -f1 | head -10 | sort"]' \
  --region "$REGION" \
  --profile "$PROFILE" \
  --query 'Command.CommandId' \
  --output text)

# Poll for command completion
for i in $(seq 1 12); do
  STATUS=$(aws ssm get-command-invocation \
    --command-id "$COMMAND_ID" \
    --instance-id "$INSTANCE_ID" \
    --region "$REGION" \
    --profile "$PROFILE" \
    --query 'Status' \
    --output text 2>/dev/null || echo "InProgress")
  if [[ "$STATUS" == "Success" ]]; then
    break
  elif [[ "$STATUS" == "Failed" || "$STATUS" == "TimedOut" || "$STATUS" == "Cancelled" ]]; then
    echo "ERROR: SSM command failed with status: $STATUS"
    exit 1
  fi
  sleep 5
done

# Get the output
OUTPUT=$(aws ssm get-command-invocation \
  --command-id "$COMMAND_ID" \
  --instance-id "$INSTANCE_ID" \
  --region "$REGION" \
  --profile "$PROFILE" \
  --query 'StandardOutputContent' \
  --output text)

if [[ -z "$OUTPUT" ]]; then
  echo "ERROR: No upgradable packages found on the instance."
  echo "This can happen if the AMI is very fresh. Try:"
  echo "  AWS_PROFILE=$PROFILE ./run-patch.sh --full-upgrade --no-snapshot"
  echo "to run a full upgrade first, then downgrade a package manually for testing."
  exit 1
fi

# Pick first 3 upgradable packages
PKG1=$(echo "$OUTPUT" | sed -n '1p' | tr -d '[:space:]')
PKG2=$(echo "$OUTPUT" | sed -n '2p' | tr -d '[:space:]')
PKG3=$(echo "$OUTPUT" | sed -n '3p' | tr -d '[:space:]')

# Build JSON array of available packages
PACKAGES="[\"$PKG1\""
[[ -n "$PKG2" ]] && PACKAGES+=", \"$PKG2\""
[[ -n "$PKG3" ]] && PACKAGES+=", \"$PKG3\""
PACKAGES+="]"

echo "Upgradable packages found:"
echo "$OUTPUT" | head -10
echo ""
echo "Selected for manifest: $PACKAGES"
echo ""

# Write manifest.json
cat > inspector/manifest.json << EOF
{
  "$INSTANCE_ID": $PACKAGES
}
EOF

echo "Written to: inspector/manifest.json"
echo ""
echo "Manifest contents:"
cat inspector/manifest.json
echo ""

# Validate JSON
python3 -c "import json; json.load(open('inspector/manifest.json')); print('JSON valid: OK')"