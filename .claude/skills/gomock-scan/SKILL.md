---
name: gomock-scan
description: Scan repositories for deprecated golang/mock usage
argument-hint: "[--create-issues]"
allowed-tools:
  - Bash(./scripts/gomock-lookup.sh:*)
  - Read
---

# gomock Deprecation Scanner

Scan GitHub organizations for repositories still using the deprecated github.com/golang/mock package instead of go.uber.org/mock.

**Arguments:** "$ARGUMENTS"

## Why This Matters

The original `github.com/golang/mock` package has been deprecated. The community has moved to `go.uber.org/mock` which is actively maintained and provides the same functionality.

## Workflow

Run the gomock lookup script with any provided options:

```bash
./scripts/gomock-lookup.sh $ARGUMENTS
```

## Options

| Option | Description |
|--------|-------------|
| `--create-issues` | Create tracking issues in affected repos |
| `--help`, `-h` | Show detailed help |

## Usage Examples

```
/gomock-scan                  # Scan only
/gomock-scan --create-issues  # Scan and create issues
/gomock-scan --help           # Show help
```

## Migration Guide

To migrate from golang/mock to uber/mock:

```bash
# Update go.mod
go get go.uber.org/mock@latest

# Update imports in code
find . -name '*.go' -exec sed -i '' 's|github.com/golang/mock|go.uber.org/mock|g' {} +

# Regenerate mocks
go generate ./...

# Remove old dependency
go mod tidy
```

## Output

- Real-time progress for each repository
- List of repos using deprecated gomock
- Updates tracking issue in telco-bot repo
