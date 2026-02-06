---
name: ioutil-scan
description: Scan repositories for deprecated io/ioutil usage
argument-hint: "[--create-issues]"
allowed-tools:
  - Bash(./scripts/ioutil-deprecation-checker.sh:*)
  - Read
---

# io/ioutil Deprecation Scanner

Scan GitHub organizations for repositories still using the deprecated io/ioutil package.

**Arguments:** "$ARGUMENTS"

## Why This Matters

The `io/ioutil` package was deprecated in Go 1.16 and its functions moved to `io` and `os` packages. While the package still exists for compatibility, new code should use the replacement functions.

## Replacements

| Deprecated | Replacement |
|------------|-------------|
| `ioutil.ReadAll` | `io.ReadAll` |
| `ioutil.ReadFile` | `os.ReadFile` |
| `ioutil.WriteFile` | `os.WriteFile` |
| `ioutil.ReadDir` | `os.ReadDir` |
| `ioutil.TempDir` | `os.MkdirTemp` |
| `ioutil.TempFile` | `os.CreateTemp` |
| `ioutil.Discard` | `io.Discard` |
| `ioutil.NopCloser` | `io.NopCloser` |

## Workflow

Run the ioutil deprecation checker with any provided options:

```bash
./scripts/ioutil-deprecation-checker.sh $ARGUMENTS
```

## Options

| Option | Description |
|--------|-------------|
| `--create-issues` | Create tracking issues in affected repos |
| `--help`, `-h` | Show detailed help |

## Usage Examples

```
/ioutil-scan                  # Scan only
/ioutil-scan --create-issues  # Scan and create issues
/ioutil-scan --help           # Show help
```

## Output

- Real-time progress for each repository
- Markdown report: `ioutil-usage-report.md`
- Updates tracking issue in telco-bot repo
