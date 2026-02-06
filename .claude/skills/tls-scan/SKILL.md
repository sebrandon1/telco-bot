---
name: tls-scan
description: Scan repositories for TLS configuration issues and security anti-patterns
argument-hint: "[--force] [--mode api|clone] [--no-tracking]"
allowed-tools:
  - Bash(./scripts/tls13-compliance-checker.sh:*)
  - Read
---

# TLS 1.3 Compliance Scanner

Scan GitHub organizations for TLS configuration issues including InsecureSkipVerify, weak TLS versions, and deprecated options.

**Arguments:** "$ARGUMENTS"

## What It Detects

| Severity | Pattern | Risk |
|----------|---------|------|
| CRITICAL | `InsecureSkipVerify: true` | MITM attacks - disables certificate verification |
| HIGH | TLS 1.0/1.1 MinVersion/MaxVersion | Known vulnerabilities (POODLE, BEAST) |
| MEDIUM | MaxVersion capped at TLS 1.2 | Prevents TLS 1.3 negotiation |
| INFO | MinVersion TLS 1.3 | May break older clients |
| INFO | PreferServerCipherSuites | Deprecated in Go 1.17+ |

## Workflow

Run the TLS compliance checker with any provided options:

```bash
./scripts/tls13-compliance-checker.sh $ARGUMENTS
```

If no arguments provided, run with defaults (clone mode, use cache).

## Options

| Option | Description |
|--------|-------------|
| `--force`, `-f` | Force refresh, ignore 6-hour cache |
| `--mode api` | Use GitHub Code Search API (no cloning, for CI) |
| `--mode clone` | Clone repos locally and scan with grep (default) |
| `--no-tracking` | Skip updating the central tracking issue |
| `--help`, `-h` | Show detailed help |

## Usage Examples

```
/tls-scan                    # Run with defaults (clone mode)
/tls-scan --mode api         # Use API mode (no disk needed)
/tls-scan --force            # Force refresh cache
/tls-scan --help             # Show help
```

## Output

- Real-time progress for each repository
- Summary by severity level
- Markdown report: `tls13-compliance-report.md`
- Updates tracking issue in telco-bot repo
