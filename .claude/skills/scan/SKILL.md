---
name: scan
description: Run repository scanning tools for security, deprecation, and compliance checks
argument-hint: "<type> [options]"
allowed-tools:
  - Bash(./scripts/tls13-compliance-checker.sh:*)
  - Bash(./scripts/xcrypto-lookup.sh:*)
  - Bash(./scripts/gomock-lookup.sh:*)
  - Bash(./scripts/ioutil-deprecation-checker.sh:*)
  - Bash(./scripts/golangci-lint-checker.sh:*)
  - Bash(./scripts/go-version-checker.sh:*)
  - Bash(./scripts/ubi-lookup.sh:*)
  - Read
---

# Repository Scanner

Run various repository scanning tools to check for security issues, deprecated code patterns, and compliance across Red Hat organizations.

**Arguments:** "$ARGUMENTS"

## Available Scan Types

| Type | Script | Description |
|------|--------|-------------|
| `tls` | tls13-compliance-checker.sh | TLS configuration issues (InsecureSkipVerify, weak versions) |
| `xcrypto` | xcrypto-lookup.sh | golang.org/x/crypto direct usage and version tracking |
| `gomock` | gomock-lookup.sh | Deprecated golang/mock usage (should use go.uber.org/mock) |
| `ioutil` | ioutil-deprecation-checker.sh | Deprecated io/ioutil usage (removed in Go 1.19+) |
| `golangci-lint` | golangci-lint-checker.sh | Outdated golangci-lint versions |
| `go-version` | go-version-checker.sh | Outdated Go versions in go.mod files |
| `ubi` | ubi-lookup.sh | UBI image version usage in Dockerfiles |
| `all` | All of the above | Run all scanners sequentially |

## Workflow

### 1. Parse Arguments

Parse "$ARGUMENTS" to determine:
- **Scan type**: One of the types above, or `all`
- **Options**: Pass-through options like `--force`, `--help`, `--create-issues`

If no arguments provided, show the available scan types and ask which to run.

### 2. Execute the Appropriate Scanner

Based on the scan type, run the corresponding script:

```bash
# TLS compliance scan
./scripts/tls13-compliance-checker.sh [options]

# x/crypto usage scan
./scripts/xcrypto-lookup.sh [options]

# gomock deprecation scan
./scripts/gomock-lookup.sh [options]

# io/ioutil deprecation scan
./scripts/ioutil-deprecation-checker.sh [options]

# golangci-lint version scan
./scripts/golangci-lint-checker.sh [options]

# Go version scan
./scripts/go-version-checker.sh [options]

# UBI image scan
./scripts/ubi-lookup.sh [options]
```

### 3. For "all" Scan Type

Run each scanner in sequence, collecting results:

1. TLS compliance
2. x/crypto usage
3. gomock deprecation
4. io/ioutil deprecation
5. golangci-lint versions
6. Go versions
7. UBI images

### 4. Report Results

After the scan completes:
- Summarize findings
- Note any generated report files (e.g., `tls13-compliance-report.md`)
- Highlight critical/high severity issues if any

## Usage Examples

**Show available scans:**
```
/scan
```

**Run TLS compliance scan:**
```
/scan tls
```

**Run x/crypto scan with issue creation:**
```
/scan xcrypto --create-issues
```

**Run all scans:**
```
/scan all
```

**Force refresh (ignore cache):**
```
/scan tls --force
```

**Get help for a specific scanner:**
```
/scan gomock --help
```

## Common Options

Most scanners support these options:

| Option | Description |
|--------|-------------|
| `--help`, `-h` | Show help for the specific scanner |
| `--force`, `-f` | Force refresh, ignore cached results |
| `--create-issues` | Create GitHub issues for findings (where supported) |
| `--no-tracking` | Skip updating central tracking issues |

## Notes

- All scans use the shared cache system in `scripts/caches/`
- Scans automatically skip forks, abandoned repos, and repos without go.mod
- Results are cached for 6 hours by default
- The TLS scan supports `--mode api` for CI/CD environments
