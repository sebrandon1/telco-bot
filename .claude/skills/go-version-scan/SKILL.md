---
name: go-version-scan
description: Scan repositories for outdated Go versions in go.mod files
argument-hint: "[--create-issues]"
allowed-tools:
  - Bash(./scripts/go-version-checker.sh:*)
  - Read
---

# Go Version Scanner

Scan GitHub organizations for repositories using outdated Go versions in their go.mod files.

**Arguments:** "$ARGUMENTS"

## Why This Matters

Keeping Go versions updated ensures:
- Security patches and vulnerability fixes
- Performance improvements
- Access to new language features
- Compatibility with updated dependencies

## Workflow

Run the Go version checker with any provided options:

```bash
./scripts/go-version-checker.sh $ARGUMENTS
```

## Options

| Option | Description |
|--------|-------------|
| `--create-issues` | Create tracking issues in affected repos |
| `--clear-cache` | Ignore cached results |
| `--help`, `-h` | Show detailed help |

## Usage Examples

```
/go-version-scan                  # Scan only
/go-version-scan --create-issues  # Scan and create issues
/go-version-scan --clear-cache    # Force fresh scan
/go-version-scan --help           # Show help
```

## Output

- Real-time progress for each repository
- Current vs recommended Go version
- Summary of repos by Go version
- Updates tracking issue in telco-bot repo
