# Test Environment for EC2 Patch Automation

Scripts to create a minimal AWS test environment for end-to-end testing of the EC2 patch automation playbook.

## Prerequisites

- AWS CLI v2 configured with a profile that has permissions to create VPC, EC2, S3, and IAM resources
- Ansible + collections installed (`ansible-galaxy collection install -r requirements.yml`)
- `session-manager-plugin` installed (for SSM Session Manager)

## Quick start

```bash
# 1. Provision infra (creates VPC, EC2, S3, IAM — ~5 min)
AWS_PROFILE=root ./test/setup-test-infra.sh

# 2. Configure inventory (instance ID is printed at the end of setup)
cp inventory/targets.yml.example inventory/targets.yml
cp inventory/group_vars/prod.yml.example inventory/group_vars/prod.yml
# Edit both files per the setup output

# 3. Fabricate inspector manifest with real upgradable packages
AWS_PROFILE=root ./test/fabricate-manifest.sh

# 4. Run Test A — Inspector-driven mode
AWS_PROFILE=root ./run-patch.sh --inspector-manifest inspector/manifest.json --no-snapshot

# 5. Verify Test A report
cat reports/$(date +%Y-%m-%d)/prod/*.json | python3 -m json.tool | head -20

# 6. Run Test B — Full dist-upgrade mode (same instance)
AWS_PROFILE=root ./run-patch.sh --full-upgrade --no-snapshot

# 7. Verify Test B report
cat reports/$(date +%Y-%m-%d)/prod/*.json | python3 -m json.tool | head -20

# 8. Teardown when done
AWS_PROFILE=root ./test/teardown-test-infra.sh
```

## What gets created

| Resource | Name / Tag | Purpose |
|----------|-----------|---------|
| VPC | `ec2-patch-test` (10.0.0.0/16) | Isolated network for test |
| Subnet | `ec2-patch-test-public` (10.0.1.0/24) | Public subnet for instance |
| Internet Gateway | `ec2-patch-test-igw` | Outbound internet for SSM endpoints |
| Route table | `ec2-patch-test-rt` | Default route to IGW |
| Security group | `ec2-patch-test-sg` | No inbound, all outbound (SSM is outbound-only) |
| EC2 instance | `ec2-patch-test` (t3.micro, Ubuntu 22.04) | Target host to patch |
| IAM role | `EC2-SSM-Patch-Role` | SSM agent permissions (`AmazonSSMManagedInstanceCore`) |
| IAM instance profile | `EC2-SSM-Patch-Profile` | Attaches role to instance |
| S3 bucket | `ssm-test-transfer-<account-id>` | SSM connection plugin file transfer |

## Test scenarios

### Test A — Inspector-driven mode

Validates that only manifest-listed packages are upgraded.

1. `fabricate-manifest.sh` queries the instance for upgradable packages via SSM and writes `inspector/manifest.json`
2. `run-patch.sh --inspector-manifest` upgrades only those packages
3. Report should show `upgrade_mode: "inspector"` and only the listed packages in `upgraded`

### Test B — Full dist-upgrade mode

Validates that all packages are upgraded.

1. `run-patch.sh --full-upgrade` runs `apt dist-upgrade` on the same instance
2. Report should show `upgrade_mode: "full"` and all upgraded packages

Both tests use `--no-snapshot` to save time. Remove the flag for a complete test with EBS snapshots.

## Cost

Under $0.05 for ~2 hours of usage:
- t3.micro: ~$0.02/hr
- 8GB EBS gp3: ~$0.002 for 2 hours
- S3: negligible
- SSM: free
- Inspector v2 (EC2): free

## Cleanup

```bash
AWS_PROFILE=root ./test/teardown-test-infra.sh
```

This terminates the instance, deletes the S3 bucket, IAM role/profile, security group, route table, IGW, subnet, and VPC. It discovers resources by tags, so no state file is needed.

## Troubleshooting

### SSM agent not registering

If setup hangs at "Waiting for SSM agent to register":
1. Check the instance has the IAM profile attached: `aws ec2 describe-instances --instance-ids <id> --profile root --query 'Reservations[0].Instances[0].IamInstanceProfile.Name'`
2. Check the instance has outbound internet access (the public subnet has a route to the IGW)
3. SSM agent can take 5-10 minutes to register on first boot

### No upgradable packages found

If `fabricate-manifest.sh` reports no upgradable packages, the AMI may be very fresh. You can:
1. Run full dist-upgrade first: `AWS_PROFILE=root ./run-patch.sh --full-upgrade --no-snapshot`
2. Or manually create `inspector/manifest.json` with any package names (even already-upgraded ones — the playbook will just report 0 upgrades for those)

### Teardown fails on VPC deletion

If the VPC won't delete, there may be lingering ENIs. Check:
```bash
aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=<vpc-id>" --profile root
```
Delete any remaining ENIs, then re-run teardown.