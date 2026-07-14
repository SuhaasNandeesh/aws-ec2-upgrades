# AGENTS.md

## What this is

Ansible-based EC2 patch automation for Ubuntu/Debian instances across 2 AWS accounts. Runs from a laptop with SSM as the transport (no SSH). Takes pre-patch EBS snapshots, runs `apt upgrade`, reboots, verifies service state matches pre-patch, writes reports.

Supports two upgrade modes:
- **Inspector-driven (default)**: upgrades only the packages listed per-instance in an Inspector v2 manifest JSON. Hosts not in the manifest are skipped with a report.
- **Full upgrade (fallback)**: upgrades all packages via `apt dist-upgrade`. Use `--full-upgrade` flag.

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

# Inspector-driven targeted upgrade (only manifest-listed packages per host)
AWS_PROFILE=your-profile ./run-patch.sh --inspector-manifest inspector/manifest.json

# Full dist-upgrade fallback (ignores manifest, upgrades everything)
AWS_PROFILE=your-profile ./run-patch.sh --full-upgrade
```

## Syntax check (verified)

```bash
ansible-playbook --syntax-check playbooks/patch.yml -i inventory/targets.yml \
  -e run_date=2026-01-01 -e report_dir=/tmp/reports -e bootstrap=false -e snapshot=true
```

## Architecture

- `run-patch.sh` → `ansible-playbook playbooks/patch.yml` with vars: `run_date`, `report_dir`, `bootstrap`, `snapshot`, `full_upgrade`, `inspector_manifest`
- `playbooks/patch.yml` — 9-play orchestrator (preflight → pre-snapshot → EBS snapshot → upgrade → reboot → post-snapshot+verify → reports patched → reports skipped → summary). `serial: 5`.
- `playbooks/tasks/preflight.yml` — checks `ec2_instance_info` + `aws ssm describe-instance-information` via CLI. If SSM not registered and `bootstrap=true`: creates `EC2-SSM-Patch-Role` + `EC2-SSM-Patch-Profile` via `amazon.aws.iam_role`/`iam_instance_profile`, attaches via `aws ec2 associate-iam-instance-profile` CLI.
- `playbooks/tasks/collect_facts.yml` — called with `snapshot_phase: pre|post`. Collects `service_facts`, enabled-stopped systemd units, docker containers, kernel, dpkg package versions.
- `playbooks/tasks/patch.yml` — stops `unattended-upgrades`, checks disk space (boot >= 500MB, root >= 1GB), loads Inspector manifest if provided, runs `apt update` + either `apt dist-upgrade` (full mode) or `apt upgrade <target_packages>` (inspector mode, with `only_upgrade: true` so only already-installed packages are touched), diffs package versions. Uses `block/rescue/always` to ensure `unattended-upgrades` is re-enabled even on failure. Sets `upgrade_failed` + `upgrade_error` facts on failure. Sets `upgrade_skipped` + `upgrade_skip_reason` if host not in manifest (inspector mode). Sets `upgrade_mode` fact (`full` or `inspector`).
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
| `inspector/manifest.json.example` | Inspector v2 manifest (instance ID → package list). Copy to `inspector/manifest.json`. |
| `playbooks/patch.yml` | Main playbook (9 phases) |
| `playbooks/tasks/preflight.yml` | SSM readiness + optional bootstrap |
| `playbooks/tasks/collect_facts.yml` | Service/docker/kernel/package snapshot |
| `playbooks/tasks/patch.yml` | apt upgrade logic (inspector-driven or full dist-upgrade) |
| `playbooks/tasks/safety-net-report.yml` | Generates error reports for unreachable hosts (Phase 7c) |
| `templates/*.j2` | Report templates |
| `filter_plugins/diff_utils.py` | `service_diff`, `docker_diff`, `package_diff`, `to_nice_json_safe` |

## Gotchas

- **`.yml.example` files are not valid inventory** — syntax-check against them will warn. Copy to `.yml` first.
- **Inspector manifest format**: flat JSON mapping instance ID → list of package names. Example at `inspector/manifest.json.example`. Export from Inspector v2 (`aws inspector2 list-findings`) or Console CSV export, trim to this format. Hosts in `targets.yml` but not in the manifest are skipped with a "skipped" report.
- **`only_upgrade: true`** in inspector mode — only upgrades packages that are already installed. If a manifest entry names a package not installed on the host, it is silently ignored (no install, no error).
- **Default mode is full dist-upgrade** — if neither `--inspector-manifest` nor `--full-upgrade` is passed, the playbook runs `apt dist-upgrade` on all hosts (backward compatible). Pass `--inspector-manifest` to switch to targeted mode.
- **`unattended-upgrades`** must be stopped during `apt upgrade` to avoid dpkg lock. Task handles this; re-enables in `always:` block. **Note**: `meta: end_host` in rescue blocks skips `always:` — the rescue path does NOT use `end_host`; instead, subsequent phases skip failed hosts via `upgrade_failed` fact checks.
- **`NEEDRESTART_MODE=a`** is required — without it, `needrestart` prompts hang the apt run indefinitely.
- **`ec2_snapshot` uses `snapshot_tags`** not `tags` — this is different from `ec2_instance` which uses `tags`.
- **S3 bucket must exist** in each target account — without it, SSM module transfer fails. Set `ssm_bucket_name` in group_vars.
- **Reports path**: `reports/<YYYY-MM-DD>/<account>/<instance-id>.{json,md}` plus `reports/<YYYY-MM-DD>/summary.{md,json}`. Created automatically by the playbook.
- **Unreachable hosts get safety-net reports**: `ignore_unreachable: true` excludes hosts from subsequent per-host plays. Phase 7c runs on `localhost` and iterates all inventory hosts to generate error reports for any without one.
- **Bootstrap IAM perms**: `--bootstrap` needs `iam:CreateRole/AttachRolePolicy/CreateInstanceProfile/AddRoleToInstanceProfile` + `ec2:AssociateIamInstanceProfile` on the laptop role. Run without `--bootstrap` for normal cycles.
- **Bootstrap reboots the instance**: after attaching the IAM profile, the instance is rebooted to force the SSM agent to pick up new IAM credentials. The agent doesn't pick up credentials without a reboot or service restart.
- **`managed_policies` format**: `amazon.aws.iam_role` expects a list of ARN strings, not dicts. Use `- "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"` not `- arn: "..."`.
- **SSM `describe-instance-information` returns "None"**: AWS CLI `--query` returns the string `"None"` when no results, not an empty string. All SSM checks must test `stdout | trim != 'None'` in addition to `length > 0`.
- **`--dry-run` is safe**: `command`/`shell` modules don't natively respect Ansible check mode, so mutating AWS CLI calls (`reboot-instances`, `associate-iam-instance-profile`) are explicitly gated with `when: not ansible_check_mode | bool`. Phase 5 (reboot) is skipped entirely via `meta: end_host`. Bootstrap path skips IAM attach + reboot and marks host as skipped. Read-only commands (`dpkg-query`, `df`, `describe-instance-information`) still run. `apt`, `systemd`, `ec2_snapshot`, `iam_role` modules respect check mode natively.
- **`dpkg-query` for package versions**: use `dpkg-query -W -f='${Package}\t${Version}\n'` (with single quotes around the format string). Do NOT use `awk` on `/var/lib/dpkg/status` — the SSM PTY eats `$2`/`$3` shell variables. Pre-upgrade versions are read in Phase 4 (not cached from Phase 2) because `set_fact` with `cacheable: true` does not persist across plays with the SSM connection.
- **Collection versions**: `amazon.aws 11.4.0` and `community.aws 11.1.0` are what got installed. The `requirements.yml` specifies `>=8.0.0`.
- **Region defaults**: `ap-south-1` (Mumbai) for prod, `eu-central-1` (Frankfurt) for nonprod. Override via group_vars or `--region` flag.
- **`reboot-instances` is non-blocking**: `aws ec2 reboot-instances` returns immediately. The playbook polls SSM agent registration (15 retries x 30s) then uses `wait_for_connection` (300s timeout) to confirm Session Manager is ready before proceeding.

## Prerequisites (laptop)

- Ansible 2.15+ (ansible-core 2.21.1 verified working)
- `boto3`, `botocore` Python packages
- AWS CLI v2 with named profiles configured (profile chaining for cross-account)
- `ansible-galaxy collection install -r requirements.yml`