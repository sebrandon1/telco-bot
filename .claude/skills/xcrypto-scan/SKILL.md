---
name: xcrypto-scan
description: Scan repositories for golang.org/x/crypto usage and version tracking
argument-hint: "[--create-issues] [--interactive]"
allowed-tools:
  - Bash(./scripts/xcrypto-lookup.sh:*)
  - Read
---

# x/crypto Usage Scanner

Scan GitHub organizations for repositories that directly use golang.org/x/crypto, tracking versions and security advisories.

**Arguments:** "$ARGUMENTS"

## What It Does

- Scans go.mod files for direct golang.org/x/crypto dependencies
- Identifies outdated versions with known security vulnerabilities
- Tracks security advisories from GitHub's advisory database
- Optionally creates tracking issues in affected repositories

## Workflow

Run the x/crypto lookup script with any provided options:

```bash
./scripts/xcrypto-lookup.sh $ARGUMENTS
```

## Options

| Option | Description |
|--------|-------------|
| `--create-issues` | Create tracking issues in repos with outdated x/crypto |
| `--interactive`, `-i` | Prompt before creating/updating/closing issues |
| `--help`, `-h` | Show detailed help |

## Usage Examples

```
/xcrypto-scan                      # Scan only (no issue creation)
/xcrypto-scan --create-issues      # Scan and create/update issues
/xcrypto-scan --create-issues -i   # Interactive issue management
/xcrypto-scan --help               # Show help
```

## Output

- Real-time progress for each repository
- Version information and security advisory status
- Markdown report: `xcrypto-usage-report.md`
- Updates tracking issue in telco-bot repo
