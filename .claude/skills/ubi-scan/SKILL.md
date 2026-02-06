---
name: ubi-scan
description: Scan repositories for UBI image version usage in Dockerfiles
argument-hint: "[options]"
allowed-tools:
  - Bash(./scripts/ubi-lookup.sh:*)
  - Read
---

# UBI Image Scanner

Scan GitHub organizations for repositories using specific UBI (Universal Base Image) versions in their Dockerfiles.

**Arguments:** "$ARGUMENTS"

## Why This Matters

Red Hat Universal Base Images (UBI) are regularly updated with:
- Security patches
- Bug fixes
- New features

Tracking UBI usage helps ensure containers are built on supported, secure base images.

## UBI Versions

| Version | Status |
|---------|--------|
| UBI 9 | Current, recommended |
| UBI 8 | Supported |
| UBI 7 | End of life, should migrate |

## Workflow

Run the UBI lookup script with any provided options:

```bash
./scripts/ubi-lookup.sh $ARGUMENTS
```

## Options

| Option | Description |
|--------|-------------|
| `--help`, `-h` | Show detailed help |

## Usage Examples

```
/ubi-scan        # Run the scan
/ubi-scan --help # Show help
```

## Output

- Real-time progress for each repository
- UBI version usage breakdown
- Repos using deprecated UBI versions
- Updates tracking issue in telco-bot repo
