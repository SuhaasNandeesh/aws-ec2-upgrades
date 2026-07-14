# Inspector Manifest

The manifest is a flat JSON file that maps each EC2 instance ID to a list of package names to upgrade. The playbook reads this file and upgrades only the listed packages per host.

## Format

```json
{
  "i-0123456789abcdef0": ["openssl", "libssl3", "nginx"],
  "i-0abcdef123456789": ["python3.10", "libc6", "tar"]
}
```

- **Key**: EC2 instance ID (as it appears in `inventory/targets.yml`)
- **Value**: list of package names exactly as they appear in `dpkg` / `apt` (e.g. `openssl`, `libssl3`, `linux-image-5.15.0-1025-aws`)

## How to create it from an Inspector v2 export

1. Export findings from the Inspector v2 console (CSV or Excel)
2. Identify the columns:
   - **Instance ID** — the EC2 instance ID (e.g. `i-0123456789abcdef0`)
   - **Package Name** — the vulnerable package name (e.g. `openssl`, `libc6`)
3. For each instance, collect the unique set of package names from all its findings
4. Build the JSON object: one key per instance ID, value is the deduplicated package list
5. Save as `inspector/manifest.json`

### Deduplication

If the same package appears in multiple findings for one instance (e.g. multiple CVEs for `openssl`), list it only once:

```json
{
  "i-0123456789abcdef0": ["openssl", "libssl3"]
}
```

Not:

```json
{
  "i-0123456789abcdef0": ["openssl", "openssl", "libssl3"]
}
```

## Validation

Before running the playbook, validate the JSON is well-formed:

```bash
python3 -c "import json; json.load(open('inspector/manifest.json')); print('OK')"
```

## Behavior

- **Host in manifest**: only the listed packages are upgraded via `apt-get upgrade <packages>`. The `only_upgrade: true` option ensures only already-installed packages are touched — if a manifest entry names a package not installed on the host, it is silently ignored (no install, no error).
- **Host in `targets.yml` but not in manifest**: skipped with a "Host not found in inspector manifest" report. No upgrade, no reboot, no snapshot.
- **`--full-upgrade` flag**: ignores the manifest entirely and runs `apt dist-upgrade` on all hosts.

## Example

Copy the example and fill in your instance IDs and packages:

```bash
cp inspector/manifest.json.example inspector/manifest.json
```

Then run:

```bash
AWS_PROFILE=your-profile ./run-patch.sh --inspector-manifest inspector/manifest.json
```