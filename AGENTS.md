# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

Telco-Bot is an automation toolset for the Red Hat Telco team. It provides GitHub repository scanning, dependency tracking, and Slack/Jira integrations across multiple Red Hat organizations (`redhat-best-practices-for-k8s`, `openshift`, `openshift-kni`, `redhat-openshift-ecosystem`, `redhatci`).

The codebase is primarily shell scripts with a minimal Go-based Slack bot framework.

## Key Commands

### Linting
```bash
make lint      # Check shell script formatting with shfmt
make format    # Auto-fix shell script formatting
```

### Running Scans
```bash
make run-all-scans           # Run all lookup scans
make run-xcrypto-scan        # Scan for golang.org/x/crypto usage
make run-gomock-scan         # Scan for deprecated golang/mock usage
make run-ubi-scan            # Scan for UBI7 image usage
make run-golangci-lint-scan  # Scan for outdated golangci-lint versions
make run-ioutil-scan         # Scan for deprecated io/ioutil usage
```

### Individual Script Usage
All scripts in `scripts/` support `--help`:
```bash
./scripts/go-version-checker.sh --help
./scripts/go-version-checker.sh                 # Read-only scan
./scripts/go-version-checker.sh --create-issues # Create GitHub issues
./scripts/go-version-checker.sh --clear-cache   # Ignore caches
```

### Cache Management
```bash
./scripts/update-caches.sh            # Update all shared caches
./scripts/update-caches.sh --create-pr # Update caches and create PR
./scripts/update-caches.sh --dry-run   # Preview changes
```

## Architecture

### Script Categories

**Repository Scanning** (`scripts/`):
- `go-version-checker.sh` - Finds outdated Go versions, creates tracking issues
- `golangci-lint-checker.sh` - Finds outdated golangci-lint versions
- `gomock-lookup.sh` - Finds deprecated golang/mock usage
- `xcrypto-lookup.sh` - Finds golang.org/x/crypto usage
- `ioutil-deprecation-checker.sh` - Finds deprecated io/ioutil usage
- `ubi-lookup.sh` - Finds specific UBI image versions in Dockerfiles
- `find-downstream-repos.sh` - Identifies forks and mirrors

**Cache Management** (`scripts/`):
- `update-caches.sh` - Comprehensive cache updater
- `update-fork-cache.sh` - Updates fork repository cache
- `update-abandoned-repo-cache.sh` - Updates inactive repo cache

**Notifications** (`scripts/`):
- `send-slack-msg.sh` - DCI certsuite statistics to Slack
- `quay-stats-msg.sh` - Quay.io pull statistics to Slack
- `send-cnf-team-jira-update.sh` - Jira updates to Slack
- `xcrypto-slack.sh` - x/crypto scan results to Slack

### Shared Cache System

All lookup scripts share centralized caches in `scripts/caches/`:
- `forks.txt` - Fork repositories (skipped in scans)
- `abandoned.txt` - Repos inactive for 6+ months (skipped)
- `no-gomod.txt` - Repos without go.mod files

Scripts automatically update these caches when discovering new entries.

### Configuration Files

Located in `scripts/`:
- `*-repo-list.txt` - Individual repos to include in scans
- `*-repo-blocklist.txt` - Repos to exclude from scans
- `xcrypto-issue-blocklist.txt` - Repos to skip for x/crypto issues

### Go Component

`main.go` contains a basic Slack RTM bot framework that can be extended for interactive queries. Requires `SLACK_TOKEN` environment variable.

## CI/CD Workflows

Located in `.github/workflows/`:
- `pre-main.yml` - Runs shfmt on PRs
- `go-version-checker-daily.yml` - Daily Go version scans
- `golangci-lint-checker-daily.yml` - Daily linter version scans
- `gomock-checker-daily.yml` - Daily gomock usage scans
- `update-caches-daily.yml` - Daily cache updates
- `xcrypto-lookup-weekly.yml` - Weekly x/crypto scans
- `ioutil-deprecation-checker-daily.yml` - Daily io/ioutil scans
- `daily-dci.yml` / `quay-query.yml` / `jira-team-update.yml` - Notification workflows

## Prerequisites

- GitHub CLI (`gh`) - authenticated with appropriate permissions
- `curl`, `jq` - for API calls and JSON processing
- `bash` 3.x+
- `shfmt` - for linting (install via package manager)

## Script Conventions

When adding new scripts:
1. Include `--help` flag support
2. Add prerequisite checks for required tools
3. Use shared color constants: `GREEN`, `RED`, `BLUE`, `YELLOW`, `BOLD`, `RESET`
4. Integrate with shared caches in `scripts/caches/`
5. Update `scripts/README.md` with documentation
