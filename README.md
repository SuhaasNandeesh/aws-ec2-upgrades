# EC2 Patch Automation

Automated OS patching for EC2 instances across multiple AWS accounts using Ansible + AWS SSM. No SSH keys or bastions required — all commands execute via SSM Session Manager.

## What it does

1. Reads a manual list of EC2 instance IDs (per account) for this patching cycle
2. Checks each instance for SSM readiness (agent registered + IAM profile)
3. Optionally bootstraps the SSM IAM role for unready instances (`--bootstrap`)
4. Takes a pre-patch EBS snapshot of the root volume (auto-detects root device)
5. Collects pre-upgrade state: running services, enabled-stopped services, docker containers, kernel, package versions
6. Checks disk space (boot >= 500 MB, root >= 1 GB) — aborts cleanly if insufficient
7. Runs `apt-get update` + `apt-get dist-upgrade` non-interactively, then `apt autoremove --purge`
8. Reboots the instance via `aws ec2 reboot-instances` (true OS reboot — preserves instance store volumes, no data loss)
9. Waits for SSM agent + Session Manager to come back online
10. Collects post-upgrade state and diffs against pre-upgrade: flags any dropped services or containers
11. Writes per-host `.json` + `.md` reports and a run summary to `reports/<date>/`
12. Every host gets a report — patched, skipped, errored, or unreachable (3-layer safety net)

---

## Prerequisites

### Laptop

| Requirement | Version (verified) | How to check |
|-------------|--------------------|--------------|
| Ansible (ansible-core) | 2.15+ (2.21.1 verified) | `ansible --version` |
| Python 3 | 3.8+ (3.12.2 verified) | `python3 --version` |
| `boto3` | latest | `python3 -c "import boto3; print(boto3.__version__)"` |
| `botocore` | latest | `python3 -c "import botocore; print(botocore.__version__)"` |
| AWS CLI v2 | 2.x | `aws --version` |
| session-manager-plugin | 1.1+ | `session-manager-plugin --version` |
| `jq` (optional) | any | `jq --version` |

### Install laptop dependencies

```bash
# Python packages
pip3 install boto3 botocore

# Ansible collections
ansible-galaxy collection install -r requirements.yml

# session-manager-plugin (macOS)
brew install --cask session-manager-plugin

# session-manager-plugin (Ubuntu/Debian)
# Download from https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html
```

### AWS IAM permissions

**Laptop role (per account) — standard patching:**

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeInstances",
        "ec2:RebootInstances",
        "ec2:CreateSnapshot",
        "ec2:CreateTags",
        "ec2:DescribeVolumes",
        "ec2:DescribeInstanceStatus",
        "ssm:StartSession",
        "ssm:SendCommand",
        "ssm:DescribeInstanceInformation",
        "ssm:GetCommandInvocation",
        "sts:AssumeRole"
      ],
      "Resource": "*"
    }
  ]
}
```

**Laptop role (per account) — bootstrap mode only (first run or new instances):**

All of the above, plus:

```json
{
  "Effect": "Allow",
  "Action": [
    "iam:CreateRole",
    "iam:AttachRolePolicy",
    "iam:GetRole",
    "iam:ListRolePolicies",
    "iam:CreateInstanceProfile",
    "iam:AddRoleToInstanceProfile",
    "iam:GetInstanceProfile",
    "iam:ListInstanceProfiles",
    "ec2:AssociateIamInstanceProfile"
  ],
  "Resource": "*"
}
```

### Instance requirements

- Ubuntu or Debian OS
- SSM Agent installed and running (pre-installed on recent Ubuntu AMIs; verify with `systemctl status snap.amazon-ssm-agent.amazon-ssm-agent.service` on the instance)
- Network path to SSM endpoints — either public internet or VPC endpoints for `ssm`, `ec2messages`, `ssmmessages`
- IAM instance profile with `AmazonSSMManagedInstanceCore` attached
  - If missing, run with `--bootstrap` to auto-create `EC2-SSM-Patch-Role` + `EC2-SSM-Patch-Profile` and attach it

### S3 bucket (required for SSM transport)

The `community.aws.aws_ssm` connection plugin uses S3 to transfer Ansible module code to the target instance. You must create an S3 bucket in **each target account**, in the same region as the instances:

```bash
# Prod account (ap-south-1)
aws s3api create-bucket \
  --bucket prod-ssm-patch-transfer \
  --region ap-south-1 \
  --create-bucket-configuration LocationConstraint=ap-south-1 \
  --profile prod

# Nonprod account (eu-central-1)
aws s3api create-bucket \
  --bucket nonprod-ssm-patch-transfer \
  --region eu-central-1 \
  --create-bucket-configuration LocationConstraint=eu-central-1 \
  --profile nonprod
```

Set the bucket name in the group_vars file for each account (see Setup step 3).

---

## Setup

Follow these steps in order. Each step is required before the first run.

### Step 1. Configure AWS CLI profiles

Cross-account access uses `~/.aws/config` profile chaining. Your laptop profile assumes a role in each target account:

```ini
# ~/.aws/config

[profile default]
region = ap-south-1

[profile prod]
source_profile = default
role_arn = arn:aws:iam::111122223333:role/ec2-patch-automation
region = ap-south-1

[profile nonprod]
source_profile = default
role_arn = arn:aws:iam::444455556666:role/ec2-patch-automation
region = eu-central-1
```

Verify:
```bash
aws sts get-caller-identity --profile prod
aws sts get-caller-identity --profile nonprod
```

### Step 2. Create S3 buckets

See the S3 bucket section above. Run the `aws s3api create-bucket` commands for each account.

### Step 3. Copy and fill in per-account group vars

```bash
cp inventory/group_vars/prod.yml.example inventory/group_vars/prod.yml
cp inventory/group_vars/nonprod.yml.example inventory/group_vars/nonprod.yml
```

Edit each file to set:
- `aws_profile` — must match the profile name in `~/.aws/config`
- `aws_region` — AWS region for this account (`ap-south-1` for Mumbai, `eu-central-1` for Frankfurt)
- `ssm_bucket_name` — S3 bucket name in this account for SSM file transfer (must NOT be empty)

Example `inventory/group_vars/prod.yml`:
```yaml
---
aws_profile: prod
aws_region: "ap-south-1"
ansible_aws_ssm_profile: "{{ aws_profile }}"
ansible_aws_ssm_region: "{{ aws_region }}"
ssm_bucket_name: "prod-ssm-patch-transfer"
```

### Step 4. Copy and fill in the per-run target list

```bash
cp inventory/targets.yml.example inventory/targets.yml
```

Add instance IDs under the appropriate account group:
```yaml
---
prod:
  hosts:
    i-0abc123def456:
    i-0def456abc789:
nonprod:
  hosts:
    i-0aaa111bbb222:
    i-0bbb222ccc333:
```

### Step 5. Install Ansible collections

```bash
ansible-galaxy collection install -r requirements.yml
```

This installs `amazon.aws >= 8.0` and `community.aws >= 8.0` (verified working with `amazon.aws 11.4.0` and `community.aws 11.1.0`).

### Step 6. Verify setup

```bash
# Syntax check (no AWS calls, no changes)
ansible-playbook --syntax-check playbooks/patch.yml \
  -i inventory/targets.yml \
  -e run_date=2026-01-01 -e report_dir=/tmp/reports \
  -e bootstrap=false -e snapshot=true

# Validate run-patch.sh catches missing config
./run-patch.sh  # should print clear errors if targets.yml or group_vars are missing
```

---

## Usage

```bash
# Standard patch run (all hosts in targets.yml)
AWS_PROFILE=your-profile ./run-patch.sh

# Patch only prod group
AWS_PROFILE=your-profile ./run-patch.sh --limit prod

# First run or new instances: auto-attach SSM IAM profiles to unready hosts
AWS_PROFILE=your-profile ./run-patch.sh --bootstrap

# Skip EBS snapshots
AWS_PROFILE=your-profile ./run-patch.sh --no-snapshot

# Dry run (Ansible check mode, no changes)
AWS_PROFILE=your-profile ./run-patch.sh --dry-run

# Override region for all groups
AWS_PROFILE=your-profile ./run-patch.sh --region eu-central-1

# Pass extra vars to ansible-playbook
AWS_PROFILE=your-profile ./run-patch.sh -e key=value

# Combine flags
AWS_PROFILE=your-profile ./run-patch.sh --limit prod --bootstrap --no-snapshot
```

### Flags

| Flag | Description |
|------|-------------|
| `--limit <group>` | Patch only the specified group (e.g. `prod`, `nonprod`) |
| `--bootstrap` | Auto-create `EC2-SSM-Patch-Role` + `EC2-SSM-Patch-Profile` and attach to unready instances. Needs extra IAM perms. |
| `--no-snapshot` | Skip pre-patch EBS snapshots |
| `--dry-run` / `--check` | Ansible check mode — no changes made |
| `--region <region>` | Override AWS region for all groups |
| `-e key=value` | Pass extra vars to ansible-playbook |

### Configurable variables

| Variable | Default | Where to set | Description |
|----------|---------|--------------|-------------|
| `aws_profile` | (per group) | group_vars | Named AWS CLI profile |
| `aws_region` | `ap-south-1` | group_vars | AWS region for this account |
| `ssm_bucket_name` | `""` (required) | group_vars | S3 bucket for SSM file transfer |
| `snapshot_wait_timeout` | `1800` (30 min) | group_vars or `-e` | Max seconds to wait for EBS snapshot to complete |

---

## Reports

Reports are written to `reports/<YYYY-MM-DD>/`:

```
reports/2026-07-12/
├── prod/
│   ├── i-0abc123def456.json
│   ├── i-0abc123def456.md
│   └── ...
├── nonprod/
│   ├── i-0aaa111bbb222.json
│   ├── i-0aaa111bbb222.md
│   └── ...
├── summary.md
└── summary.json
```

### Per-host report

Each per-host report (`.json` + `.md`) contains:

- **Status**: `patched`, `skipped`, `no_ssm`, or `error`
- **Skip reason**: empty for patched hosts; error message or skip reason for others
- **Snapshot ID**: EBS snapshot ID if taken
- **Pre-upgrade snapshot**: running services, enabled-stopped services, docker containers, kernel
- **Upgraded packages**: list with name, old version, new version
- **Rebooted**: true/false
- **Post-upgrade snapshot**: same fields as pre-upgrade
- **Service drift**: dropped (was running, now not) and added (now running, was not)
- **Docker drift**: dropped/added container names
- **Kernel changed**: true/false
- **Verified**: true if no services or containers were dropped

### Run summary

`summary.md` and `summary.json` contain:
- Total hosts targeted, patched, skipped, errored, with drift
- Per-account breakdown (targeted, patched, skipped, errors, total upgrades, skipped hosts, drift hosts)
- Aggregated list of all upgraded packages across the fleet

---

## How it works

```
run-patch.sh
  └── ansible-playbook playbooks/patch.yml
        ├── Phase 1:  Preflight      — SSM readiness + optional bootstrap (block/rescue)
        ├── Phase 2:  Pre-snapshot    — collect services, docker, kernel, packages (block/rescue)
        ├── Phase 3:  EBS snapshot   — auto-detect root device, create snapshot (block/rescue, retry)
        ├── Phase 4:  Upgrade         — disk check + apt dist-upgrade + autoremove (block/rescue/always)
        ├── Phase 5:  Reboot          — reboot-instances (preserves instance store) + SSM reconnect (block/rescue)
        ├── Phase 6:  Post-snapshot   — collect post-upgrade facts + drift verification (block/rescue)
        ├── Phase 7:  Reports         — per-host .json + .md for patched hosts
        ├── Phase 7b: Reports         — error/skip reports for non-patched hosts
        ├── Phase 7c: Safety net      — generic error report for any host missing one
        └── Phase 8:  Summary         — aggregated summary.md + summary.json
```

### Design: every host gets a report, no matter what

Every phase uses `block/rescue` to capture failures as facts (`phase_error`) rather than letting Ansible mark the host as failed. This means every host continues to the report phases:

| Failure scenario | Report source |
|---|---|
| Host patched successfully | Phase 7 |
| Preflight skip (not running, no SSM, bootstrap disabled) | Phase 7b |
| Upgrade failed (apt error, disk space) | Phase 7b |
| Phase 1/2/3/5/6 failed (SSM drop, snapshot error, reboot error) | Phase 7b (via `phase_error`) |
| Host unreachable from Phase 1 (SSM down) | Phase 7c (safety net: no file exists) |
| Report rendering itself failed in Phase 7/7b | Phase 7c (`ignore_errors` on templates, file missing) |

### Reboot: no data loss

Uses `aws ec2 reboot-instances` — a true OS reboot. This is NOT `ec2_instance: state=restarted` (which does stop/start and destroys instance store/ephemeral volumes). After reboot, the playbook:
1. Polls SSM agent registration (15 retries x 30s)
2. Calls `meta: reset_connection` to drop the stale SSM session
3. Uses `wait_for_connection` (300s timeout) to confirm Session Manager is ready

### Upgrade: safe and clean

1. Stops `unattended-upgrades` to avoid apt lock contention
2. Checks disk space (boot >= 500 MB, root >= 1 GB) — aborts with clear message if insufficient
3. Runs `apt-get update` + `apt-get dist-upgrade` with `DEBIAN_FRONTEND=noninteractive`, `force-confold`, `force-confdef`, `NEEDRESTART_MODE=a`, `force_apt_get: true`
4. Runs `apt autoremove --purge` to clean up obsolete packages
5. Re-enables `unattended-upgrades` in the `always` block — runs even if upgrade fails

### Connection: SSM only, no SSH

- `ansible_connection: community.aws.aws_ssm` — all commands execute via SSM Session Manager
- Module code is transferred via S3 (requires the S3 bucket in each target account)
- `ignore_unreachable: true` on all host-facing plays ensures SSM connection failures don't drop hosts from subsequent plays

---

## Files

| File | Purpose |
|------|---------|
| `run-patch.sh` | Entry point script. Parses flags, validates config, calls ansible-playbook. |
| `ansible.cfg` | Ansible configuration. `stdout_callback=default`, `forks=10`, `collections_path=./collections` |
| `requirements.yml` | Collection dependencies (`amazon.aws>=8.0`, `community.aws>=8.0`) |
| `inventory/targets.yml.example` | Template for per-run instance list (copy to `targets.yml`) |
| `inventory/group_vars/all.yml` | SSM connection config, defaults (applies to all hosts) |
| `inventory/group_vars/prod.yml.example` | Prod account vars template (copy to `prod.yml`) |
| `inventory/group_vars/nonprod.yml.example` | Nonprod account vars template (copy to `nonprod.yml`) |
| `playbooks/patch.yml` | Main playbook (10 phases: 1-8 + 7b + 7c) |
| `playbooks/tasks/preflight.yml` | SSM readiness check + optional IAM bootstrap |
| `playbooks/tasks/collect_facts.yml` | Service/docker/kernel/package collection (pre and post) |
| `playbooks/tasks/patch.yml` | apt dist-upgrade logic with disk check, autoremove, block/rescue/always |
| `templates/host-report.json.j2` | Per-host JSON report template |
| `templates/host-report.md.j2` | Per-host Markdown report template |
| `templates/summary.md.j2` | Run summary Markdown template |
| `filter_plugins/diff_utils.py` | Custom Ansible filters: `service_diff`, `docker_diff`, `package_diff`, `to_nice_json_safe` |

---

## Notes

- **Serial=5**: hosts are processed in batches of 5 to avoid overwhelming SSM or the AWS API.
- **dist-upgrade**: uses `apt-get dist-upgrade` (not `safe-upgrade`) to install new kernel images and handle dependency changes required for security patches.
- **Non-interactive apt**: uses `DEBIAN_FRONTEND=noninteractive`, `force-confold`, `force-confdef`, `NEEDRESTART_MODE=a`, `force_apt_get: true` to prevent hangs.
- **unattended-upgrades**: stopped before upgrade to avoid apt lock contention, re-enabled in `always` block (runs even on failure).
- **Reboot**: uses `aws ec2 reboot-instances` (true OS reboot, preserves instance store volumes — no data loss). NOT `ec2_instance: state=restarted` (which does stop/start).
- **SSM reconnect**: after reboot, `meta: reset_connection` drops stale session, then `wait_for_connection` (300s) waits for Session Manager.
- **Disk space check**: verifies boot >= 500 MB and root >= 1 GB before upgrade. Aborts with clear message if insufficient.
- **Autoremove**: runs `apt autoremove --purge` after upgrade to prevent /boot filling up over time.
- **Retry on transient failures**: all AWS API calls (`ec2_instance_info`, `ec2_snapshot`, `reboot-instances`) retry 3 times with 10s delay. SSM agent poll retries 15 times with 30s delay.
- **Root device**: auto-detected from `ec2_instance_info` `root_device_name` field. Works with `/dev/sda1`, `/dev/xvda`, NVMe devices, etc.
- **EBS snapshot**: waits up to `snapshot_wait_timeout` (default 1800s / 30 min) for snapshot completion. Configurable via group_vars or `-e`.
- **Bootstrap mode**: creates `EC2-SSM-Patch-Role` with `AmazonSSMManagedInstanceCore` + `EC2-SSM-Patch-Profile` and attaches to unready instances. Only needs to run once per new instance. Requires extra IAM permissions.
- **Cross-account**: no `accounts.yml` needed. Access is via `~/.aws/config` profile chaining (`source_profile` + `role_arn`).
- **Regions**: defaults are `ap-south-1` (Mumbai) for prod and `eu-central-1` (Frankfurt) for nonprod. Override via group_vars or `--region` flag.
- **Report safety net**: every host in the inventory gets a report file. Phase 7b handles skipped/errored hosts, Phase 7c catches anything missed (unreachable hosts, template rendering failures).
- **Validation**: `run-patch.sh` validates that `inventory/targets.yml` exists, at least one group_vars `.yml` file exists, and `ssm_bucket_name` is non-empty. Exits with a clear error message if any check fails.

---

## Troubleshooting

### `session-manager-plugin` not found

The SSM connection plugin requires the session-manager-plugin binary on your laptop.

**macOS:**
```bash
brew install --cask session-manager-plugin
```

**Ubuntu/Debian:**
Download and install from the [AWS docs](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html).

Verify:
```bash
session-manager-plugin --version
```

### SSM agent not registering after bootstrap

If `--bootstrap` attaches the IAM profile but SSM agent still doesn't register within 5 minutes:

1. Check the instance has network access to SSM endpoints (`ssm`, `ec2messages`, `ssmmessages`) — either via public internet or VPC endpoints
2. Check the SSM agent is running on the instance: `systemctl status snap.amazon-ssm-agent.amazon-ssm-agent.service`
3. Check the IAM role `EC2-SSM-Patch-Role` has `AmazonSSMManagedInstanceCore` attached
4. SSM agent can take 5-10 minutes to register after profile attachment on first boot

### S3 bucket not found / 307 redirect

The SSM connection plugin uses S3 for module file transfer. If you see S3 errors:

1. Verify the bucket exists in the target account: `aws s3 ls --profile prod`
2. Verify the bucket name in group_vars matches: `grep ssm_bucket_name inventory/group_vars/prod.yml`
3. If using `--region` override, ensure the bucket is in the same region as the instances
4. If the bucket is in a different region than the instance, set `ansible_aws_ssm_s3_addressing_style: virtual` in group_vars

### apt lock contention

If apt fails with "Could not get lock /var/lib/dpkg/lock":

1. The playbook stops `unattended-upgrades` before upgrade and re-enables it after — this should prevent lock contention
2. If a previous run was interrupted, the `unattended-upgrades` service may still be running. SSH (via Session Manager) and stop it: `sudo systemctl stop unattended-upgrades`
3. Check for stuck dpkg: `sudo lsof /var/lib/dpkg/lock`

### Insufficient disk space

The playbook checks disk space before upgrade and aborts with a clear message if:
- `/boot` has less than 500 MB free
- `/` has less than 1 GB free

To fix:
1. Remove old kernels: `sudo apt-get autoremove --purge` (the playbook does this automatically after future upgrades)
2. Clear apt cache: `sudo apt-get clean`
3. Remove unused packages: `sudo apt-get autoremove`

### Group_vars validation errors

`run-patch.sh` validates config before running. If you see:

- `ERROR: inventory/targets.yml not found` — copy `targets.yml.example` to `targets.yml` and add instance IDs
- `ERROR: No group_vars files found` — copy `prod.yml.example` to `prod.yml` and/or `nonprod.yml.example` to `nonprod.yml`
- `ERROR: ssm_bucket_name is empty` — set `ssm_bucket_name` to a non-empty bucket name in the group_vars file

### Host gets error report but should have been patched

Check the `skip_reason` field in the host's JSON report:
```bash
cat reports/<date>/<account>/<instance-id>.json | jq '.skip_reason'
```

Common reasons:
- `Phase 2 failed: ...` — SSM connection dropped during fact collection
- `Phase 3 failed: ...` — EBS snapshot creation failed (check IAM perms, AWS API limits)
- `Phase 5 failed: ...` — Reboot or SSM reconnection failed (check instance health)
- `Phase 6 failed: ...` — Post-upgrade fact collection failed (SSM connection dropped)

### Host shows as error with "Host unreachable - SSM connection failed"

This means the host was never reachable via SSM from Phase 1. Check:
1. Is the instance running? `aws ec2 describe-instances --instance-ids i-xxx --profile prod --query 'Reservations[0].Instances[0].State.Name'`
2. Is SSM agent registered? `aws ssm describe-instance-information --filters Key=InstanceIds,Values=i-xxx --profile prod`
3. Does the instance have an IAM profile with SSM permissions?
4. Does the instance have network access to SSM endpoints?