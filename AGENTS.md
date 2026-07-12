# AGENTS.md

## What this is

Ansible-based EC2 patch automation for Ubuntu/Debian instances across 2 AWS accounts. Runs from a laptop with SSM as the transport (no SSH). Takes pre-patch EBS snapshots, runs `apt upgrade`, reboots, verifies service state matches pre-patch, writes reports.

## Quick start (verified commands)

```bash
# Install collections (required before first run)
ansible-galaxy collection install -r requirements.yml

# Standard patch run
AWS_PROFILE=your-profile ./run-patch.sh

# Patch only one account group
AWS_PROFILE=your-profile ./run-patch.sh --limit prod

# First run / new instances: auto-attach SSM IAM profiles to unready hosts
AWS_PROFILE=your-profile ./run-patch.sh --bootstrap

# Skip EBS snapshots
AWS_PROFILE=your-profile ./run-patch.sh --no-snapshot

# Override region for all groups
AWS_PROFILE=your-profile ./run-patch.sh --region eu-central-1

# Dry run (Ansible check mode, no changes)
AWS_PROFILE=your-profile ./run-patch.sh --dry-run
```

## Syntax check (verified)

```bash
ansible-playbook --syntax-check playbooks/patch.yml -i inventory/targets.yml \
  -e run_date=2026-01-01 -e report_dir=/tmp/reports -e bootstrap=false -e snapshot=true
```

## Architecture

- `run-patch.sh` → `ansible-playbook playbooks/patch.yml` with vars: `run_date`, `report_dir`, `bootstrap`, `snapshot`
- `playbooks/patch.yml` — 9-play orchestrator (preflight → pre-snapshot → EBS snapshot → upgrade → reboot → post-snapshot+verify → reports patched → reports skipped → summary). `serial: 5`.
- `playbooks/tasks/preflight.yml` — checks `ec2_instance_info` + `aws ssm describe-instance-information` via CLI. If SSM not registered and `bootstrap=true`: creates `EC2-SSM-Patch-Role` + `EC2-SSM-Patch-Profile` via `amazon.aws.iam_role`/`iam_instance_profile`, attaches via `aws ec2 associate-iam-instance-profile` CLI.
- `playbooks/tasks/collect_facts.yml` — called with `snapshot_phase: pre|post`. Collects `service_facts`, enabled-stopped systemd units, docker containers, kernel, dpkg package versions.
- `playbooks/tasks/patch.yml` — stops `unattended-upgrades`, checks disk space (boot >= 500MB, root >= 1GB), runs `apt update` + `apt dist-upgrade` (noninteractive: `DEBIAN_FRONTEND=noninteractive`, `dpkg_options: force-confold,force-confdef`, `NEEDRESTART_MODE=a`, `force_apt_get: true`), diffs package versions. Uses `block/rescue/always` to ensure `unattended-upgrades` is re-enabled even on failure. Sets `upgrade_failed` + `upgrade_error` facts on failure.
- `filter_plugins/diff_utils.py` — custom filters: `service_diff`, `docker_diff`, `package_diff`, `to_nice_json_safe`.
- `templates/` — `host-report.json.j2`, `host-report.md.j2`, `summary.md.j2`.

## Key design decisions

- **SSM transport**: `ansible_connection: community.aws.aws_ssm` in `inventory/group_vars/all.yml`. No SSH keys or bastions.
- **S3 bucket required**: the SSM connection plugin uses S3 for module file transfer. Set `ssm_bucket_name` in each group_vars file. Bucket must exist in the target account.
- **SSM profile/region vars**: the connection plugin reads `ansible_aws_ssm_profile` (not `aws_profile`), `ansible_aws_ssm_region` (not `aws_region`), and `ansible_aws_ssm_bucket_name`. Group_vars set `aws_profile`/`aws_region` as custom vars for module params and map them to the `ansible_aws_ssm_*` equivalents.
- **Reboot uses `aws ec2 reboot-instances`**: NOT `ec2_instance: state=restarted` (which does stop/start and destroys instance store data). Uses AWS CLI `reboot-instances` for true OS reboot that preserves ephemeral volumes. Then waits for SSM agent registration + `wait_for_connection` for Session Manager readiness.
- **Root device auto-detection**: uses `ec2_instance_info` `root_device_name` field instead of hardcoding `/dev/sda1`. Works with xvda, NVMe, etc.
- **Manual targeting**: no dynamic inventory. Operator fills `inventory/targets.yml` with instance IDs per account group each cycle.
- **Cross-account via AWS CLI profiles**: no `accounts.yml`. `~/.aws/config` profile chaining (`source_profile` + `role_arn`) handles assume-role. Each group's `aws_profile` name maps to a CLI profile.
- **No `ssm_instance_info` module exists**: SSM readiness is checked via `aws ssm describe-instance-information` CLI, not an Ansible module.
- **IAM instance profile attach**: no Ansible module exists for `ec2 associate-iam-instance-profile`. Uses AWS CLI.
- **ec2_snapshot uses `snapshot_tags`**: not `tags`. This is module-specific to `amazon.aws.ec2_snapshot`.

## File map

| Path | Purpose |
|------|---------|
| `run-patch.sh` | Entry point. Parses flags, sets up report dir, calls ansible-playbook. |
| `ansible.cfg` | `inventory=inventory/targets.yml`, `gathering=explicit`, `forks=10`, `collections_path=./collections` |
| `requirements.yml` | `amazon.aws>=8.0`, `community.aws>=8.0` |
| `inventory/targets.yml.example` | Per-run instance list (copy to `inventory/targets.yml`) |
| `inventory/group_vars/all.yml` | SSM connection config, `ansible_python_interpreter=/usr/bin/python3`, S3 bucket var, region default |
| `inventory/group_vars/prod.yml.example` | `aws_profile`, `aws_region`, `ssm_bucket_name` for prod account |
| `inventory/group_vars/nonprod.yml.example` | Same for nonprod |
| `playbooks/patch.yml` | Main playbook (9 phases) |
| `playbooks/tasks/preflight.yml` | SSM readiness + optional bootstrap |
| `playbooks/tasks/collect_facts.yml` | Service/docker/kernel/package snapshot |
| `playbooks/tasks/patch.yml` | apt upgrade logic |
| `templates/*.j2` | Report templates |
| `filter_plugins/diff_utils.py` | `service_diff`, `docker_diff`, `package_diff`, `to_nice_json_safe` |

## Gotchas

- **`.yml.example` files are not valid inventory** — syntax-check against them will warn. Copy to `.yml` first.
- **`unattended-upgrades`** must be stopped during `apt upgrade` to avoid dpkg lock. Task handles this; re-enables after.
- **`NEEDRESTART_MODE=a`** is required — without it, `needrestart` prompts hang the apt run indefinitely.
- **`ec2_snapshot` uses `snapshot_tags`** not `tags` — this is different from `ec2_instance` which uses `tags`.
- **S3 bucket must exist** in each target account — without it, SSM module transfer fails. Set `ssm_bucket_name` in group_vars.
- **Reports path**: `reports/<YYYY-MM-DD>/<account>/<instance-id>.{json,md}` plus `reports/<YYYY-MM-DD>/summary.{md,json}`. Created automatically by the playbook.
- **Bootstrap IAM perms**: `--bootstrap` needs `iam:CreateRole/AttachRolePolicy/CreateInstanceProfile/AddRoleToInstanceProfile` + `ec2:AssociateIamInstanceProfile` on the laptop role. Run without `--bootstrap` for normal cycles.
- **Collection versions**: `amazon.aws 11.4.0` and `community.aws 11.1.0` are what got installed. The `requirements.yml` specifies `>=8.0.0`.
- **Region defaults**: `ap-south-1` (Mumbai) for prod, `eu-central-1` (Frankfurt) for nonprod. Override via group_vars or `--region` flag.
- **`reboot-instances` is non-blocking**: `aws ec2 reboot-instances` returns immediately. The playbook polls SSM agent registration (15 retries x 30s) then uses `wait_for_connection` (300s timeout) to confirm Session Manager is ready before proceeding.

## Prerequisites (laptop)

- Ansible 2.15+ (ansible-core 2.21.1 verified working)
- `boto3`, `botocore` Python packages
- AWS CLI v2 with named profiles configured (profile chaining for cross-account)
- `ansible-galaxy collection install -r requirements.yml`