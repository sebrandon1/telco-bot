# Scripts Documentation

This directory contains automation scripts for monitoring and managing GitHub repositories across multiple Red Hat organizations.

## Table of Contents

- [Repository Scanning Scripts](#repository-scanning-scripts)
  - [go-version-checker.sh](#go-version-checkersh)
  - [gomock-lookup.sh](#gomock-lookupsh)
  - [ioutil-deprecation-checker.sh](#ioutil-deprecation-checkersh)
  - [golangci-lint-checker.sh](#golangci-lint-checkersh)
  - [xcrypto-lookup.sh](#xcrypto-lookupsh)
  - [tls13-compliance-checker.sh](#tls13-compliance-checkersh)
  - [ubi-lookup.sh](#ubi-lookupsh)
  - [find-downstream-repos.sh](#find-downstream-repossh)
- [Cache Management Scripts](#cache-management-scripts)
  - [update-fork-cache.sh](#update-fork-cachesh)
  - [update-abandoned-repo-cache.sh](#update-abandoned-repo-cachesh)
- [Notification Scripts](#notification-scripts)
  - [send-slack-msg.sh](#send-slack-msgsh)
  - [quay-stats-msg.sh](#quay-stats-msgsh)
  - [send-cnf-team-jira-update.sh](#send-cnf-team-jira-updatesh)
  - [sanitize-raw-jira-format.sh](#sanitize-raw-jira-formatsh)
- [Configuration Files](#configuration-files)

---

## Repository Scanning Scripts

### go-version-checker.sh

**Purpose**: Scans GitHub organizations for repositories using outdated Go versions (versions listed in the "Archived" section of https://go.dev/dl/).

**Features**:
- Scans multiple organizations in parallel
- Checks go.mod files for Go version directives
- Creates/updates GitHub issues on outdated repositories
- Maintains a central tracking issue in telco-bot repo
- Caches non-Go repos and forks for performance
- Skips repositories inactive for >1 year

**Usage**:
```bash
# Basic scan (read-only mode)
./go-version-checker.sh

# Create/update GitHub issues for outdated repos
./go-version-checker.sh --create-issues

# Check patch versions too (e.g., flag 1.25.1 when 1.25.4 is latest)
./go-version-checker.sh --check-minor

# Skip updating the central tracking issue
./go-version-checker.sh --no-tracking

# Clear all caches and rescan
./go-version-checker.sh --clear-cache

# Show help
./go-version-checker.sh --help
```

**Configuration**:
- Edit `ORGS` array in script to change scanned organizations
- Add individual repos to `go-version-repo-list.txt` (one per line)
- Exclude repos via `go-version-repo-blocklist.txt`

**Output**:
- Real-time progress for each repository
- Per-organization summary
- Detailed report of outdated repositories
- Optional GitHub issues on each outdated repo
- Central tracking issue: "Tracking Out of Date Golang Versions"

**Example Output**:
```
✅ Repository: org/repo on branch main... ✓ Up-to-date (go1.23.4)
❌ Repository: org/old-repo on branch main... ✗ OUTDATED (go1.19.0)
```

---

### gomock-lookup.sh

**Purpose**: Identifies repositories using the deprecated `github.com/golang/mock` package, which was archived in June 2023.

**Features**:
- Scans go.mod files for direct dependencies (excludes indirect)
- Generates markdown report with findings
- Maintains central tracking issue in telco-bot repo
- Caches forks, non-Go repos, and abandoned repos
- Skips repos with no commits in last 6 months

**Usage**:
```bash
# Scan all default organizations
./gomock-lookup.sh
```

**Configuration**:
- Edit `ORGS` array in script to change scanned organizations
- Add individual repos to `gomock-repo-list.txt` (one per line)

**Output**:
- Real-time progress for each repository
- Per-organization summary
- `gomock-usage-report.md` - Markdown report with migration guide
- Central tracking issue: "Tracking Deprecated golang/mock Usage"

**Migration Recommendation**:
The script recommends migrating to `go.uber.org/mock`, the maintained fork of golang/mock.

---

### ioutil-deprecation-checker.sh

**Purpose**: Identifies repositories using the deprecated `io/ioutil` package, which was deprecated in Go 1.16 (February 2021). The functionality has been moved to the `io` and `os` packages.

**Features**:
- Uses GitHub's code search API to detect io/ioutil usage in Go files
- Intelligent results caching to avoid rate limits (6-hour cache lifetime)
- Generates markdown report with migration guide
- Maintains central tracking issue in telco-bot repo
- Caches forks, non-Go repos, and abandoned repos
- Skips repos with no commits in last 6 months
- Tracks API success/failure and caches results

**Usage**:
```bash
# Scan all default organizations (uses cache if < 6 hours old)
./ioutil-deprecation-checker.sh

# Force refresh, ignoring cache
./ioutil-deprecation-checker.sh --force

# Show help
./ioutil-deprecation-checker.sh --help
```

**Configuration**:
- Edit `ORGS` array in script to change scanned organizations

**Caching**:
The script maintains a JSON results cache (`.ioutil-checker-results.json`) that stores:
- Which repos use io/ioutil
- Which repos don't use it
- Whether API calls succeeded
- Last check timestamp

The cache is valid for 6 hours and significantly reduces API calls on subsequent runs. Use `--force` to bypass the cache.

**Output**:
- Real-time progress for each repository
- Per-organization summary
- `ioutil-usage-report.md` - Markdown report with migration guide
- Central tracking issue: "Tracking Deprecated io/ioutil Package Usage"

**Migration Mapping**:
The script provides a comprehensive migration guide showing the replacement for each deprecated function:

| Deprecated (io/ioutil) | Replacement | Package |
|------------------------|-------------|---------|
| `ioutil.Discard` | `io.Discard` | io |
| `ioutil.NopCloser` | `io.NopCloser` | io |
| `ioutil.ReadAll` | `io.ReadAll` | io |
| `ioutil.ReadDir` | `os.ReadDir` | os |
| `ioutil.ReadFile` | `os.ReadFile` | os |
| `ioutil.TempDir` | `os.MkdirTemp` | os |
| `ioutil.TempFile` | `os.CreateTemp` | os |
| `ioutil.WriteFile` | `os.WriteFile` | os |

**Reference**: [Go 1.16 Release Notes](https://go.dev/doc/go1.16)

---

### golangci-lint-checker.sh

**Purpose**: Scans GitHub organizations for repositories using outdated versions of golangci-lint, a popular Go linters aggregator.

**Features**:
- Detects golangci-lint usage in multiple locations:
  - GitHub Actions workflows (`.github/workflows/*.yml`)
  - Makefiles (`Makefile`)
  - Configuration files (`.golangci.yml`, `.golangci.yaml`)
- Compares versions against the latest release from GitHub
- Creates/updates GitHub issues on outdated repositories (optional)
- Maintains a central tracking issue in telco-bot repo
- Caches non-Go repos, forks, and abandoned repos for performance
- Generates markdown report with update instructions
- Skips repositories inactive for >6 months

**Usage**:
```bash
# Basic scan (read-only mode)
./golangci-lint-checker.sh

# Create/update GitHub issues for outdated repos
./golangci-lint-checker.sh --create-issues

# Skip updating the central tracking issue
./golangci-lint-checker.sh --no-tracking

# Clear all caches and rescan
./golangci-lint-checker.sh --clear-cache

# Show help
./golangci-lint-checker.sh --help
```

**Configuration**:
- Edit `ORGS` array in script to change scanned organizations
- Add individual repos to `golangci-lint-repo-list.txt` (one per line)
- Exclude repos via `golangci-lint-repo-blocklist.txt`

**Output**:
- Real-time progress for each repository
- Per-organization summary
- `golangci-lint-report.md` - Markdown report with update instructions
- Optional GitHub issues on each outdated repo
- Central tracking issue: "Tracking Outdated GolangCI-Lint Versions"

**Example Output**:
```
✅ Repository: org/repo on branch main... ✓ Up-to-date (v1.55.2)
❌ Repository: org/old-repo on branch main... ✗ OUTDATED (v1.50.0 in .github/workflows/lint.yml)
```

**Detection Patterns**:
The script searches for golangci-lint version specifications in:
1. GitHub Actions: `golangci/golangci-lint-action@vX.Y.Z`
2. Makefiles: `GOLANGCI_LINT_VERSION = vX.Y.Z`
3. Makefiles: `go install github.com/golangci/golangci-lint/cmd/golangci-lint@vX.Y.Z`
4. Config files: Version specifications in `.golangci.yml` or `.golangci.yaml`

**Update Recommendation**:
The script provides specific instructions for updating golangci-lint in different contexts (GitHub Actions, Makefiles, direct installation).

---

### xcrypto-lookup.sh

**Purpose**: Scans repositories for direct usage of the `golang.org/x/crypto` package, useful for security audits and dependency tracking.

**Features**:
- Detects direct dependencies (excludes indirect)
- Scans multiple organizations
- Fast scanning with progress indicators

**Usage**:
```bash
# Scan all default organizations
./xcrypto-lookup.sh
```

**Configuration**:
- Edit `ORGS` array in script to change scanned organizations
- Add individual repos to `xcrypto-repo-list.txt` (one per line)

**Output**:
- Real-time progress for each repository
- Per-organization summary
- Final statistics with usage percentage

---

### tls13-compliance-checker.sh

**Purpose**: Scans GitHub organizations for repositories with TLS configuration issues and security anti-patterns. Identifies insecure settings like `InsecureSkipVerify`, weak TLS versions, and deprecated options.

**Features**:
- Dual-mode scanning: clone-based (fast, local) or API-based (for CI/CD)
- Detects multiple TLS anti-patterns with severity classification
- Intelligent results caching (6-hour cache lifetime)
- Generates markdown report with remediation guide
- Maintains central tracking issue with organization-level statistics
- Shows fully compliant organizations and resource links
- Caches forks, non-Go repos, and abandoned repos
- Skips vendor, test directories, and test files

**Severity Levels**:

| Severity | Pattern | Risk |
|----------|---------|------|
| CRITICAL | `InsecureSkipVerify: true` | Disables TLS certificate verification (MITM vulnerability) |
| HIGH | `MinVersion`/`MaxVersion` TLS 1.0 or 1.1 | Known vulnerabilities (POODLE, BEAST) |
| MEDIUM | `MaxVersion` TLS 1.2 | Prevents TLS 1.3 negotiation |
| INFO | `MinVersion` TLS 1.3, `PreferServerCipherSuites` | May break older clients, deprecated in Go 1.17+ |

**Usage**:
```bash
# Scan using clone mode (default, fastest for local use)
./tls13-compliance-checker.sh

# Scan using API mode (for GitHub Actions, no cloning required)
./tls13-compliance-checker.sh --mode api

# Force refresh, ignoring cache
./tls13-compliance-checker.sh --force

# Skip updating the central tracking issue
./tls13-compliance-checker.sh --no-tracking

# Show help
./tls13-compliance-checker.sh --help
```

**Configuration**:
- Edit `ORGS` array in script to change scanned organizations
- Exclude repos via `tls13-repo-blocklist.txt`

**Caching**:
The script maintains a JSON results cache (`.tls13-checker-results.json`) that stores:
- TLS configuration findings per repository
- Branch information for file hyperlinks
- Last check timestamp

The cache is valid for 6 hours and significantly reduces scanning time on subsequent runs. Use `--force` to bypass the cache.

**Output**:
- Real-time progress for each repository
- Per-organization severity summary
- `tls13-compliance-report.md` - Markdown report with remediation guide
- Central tracking issue: "Tracking TLS Configuration Compliance"

**Tracking Issue Features**:
- Organizations Scanned table with repo counts and compliance status
- Fully Compliant Organizations highlight section
- Findings grouped by organization and severity
- File hyperlinks to exact locations in source code
- Remediation guide with code examples
- Resource links (RFC 8446, Go crypto/tls, OWASP, Mozilla SSL config generator)
- Security advisory references (POODLE, BEAST CVEs)

**Example Output**:
```
org/repo on branch main... no issues found
org/other-repo on branch main... 2 issue(s) found
```

---

### ubi-lookup.sh

**Purpose**: Scans Dockerfiles and Containerfiles for specific UBI (Universal Base Image) versions. Particularly useful for identifying EOL images like UBI7.

**Features**:
- Searches common Dockerfile locations
- Reports other UBI versions found in each repo
- Supports scanning specific organizations
- Tracks version distribution

**Usage**:
```bash
# Scan all orgs for UBI7
./ubi-lookup.sh --version ubi7

# Scan specific org for UBI7-minimal
./ubi-lookup.sh --version ubi7-minimal --org openshift

# Scan for UBI8 in specific org
./ubi-lookup.sh --version ubi8 --org redhat-best-practices-for-k8s

# Show help
./ubi-lookup.sh --help
```

**Supported Container Files**:
- `Dockerfile`
- `Containerfile`
- `build/Dockerfile`
- `docker/Dockerfile`
- `.dockerfiles/Dockerfile`
- `dockerfiles/Dockerfile`

**Configuration**:
- Add individual repos to `ubi-repo-list.txt` (one per line)

**Output**:
- Real-time progress with repository counter
- Found UBI versions in non-matching repos
- Distribution summary of other UBI versions
- Execution time statistics

**Example Output**:
```
[45/127] 📂 org/repo on branch main... ✓ USES ubi7 in Dockerfile
[46/127] 📂 org/other on branch main... ✗ NO ubi7 (found: ubi8,ubi9)
```

---

### find-downstream-repos.sh

**Purpose**: Identifies repositories that are downstream forks or mirrors of upstream projects, which typically shouldn't receive automated update issues.

**Features**:
- Detects GitHub forks via API
- Pattern matching for common upstream projects
- Description analysis for downstream indicators
- Outputs blocklist-ready format

**Usage**:
```bash
# Scan default organization (openshift)
./find-downstream-repos.sh

# Scan specific organization
./find-downstream-repos.sh --org redhat-openshift-ecosystem

# Limit number of repos scanned
./find-downstream-repos.sh --limit 500

# Save to file
./find-downstream-repos.sh --output downstream-repos.txt

# Show help
./find-downstream-repos.sh --help
```

**Detection Methods**:
1. GitHub fork status
2. Repository name patterns (prometheus, grafana, thanos, etc.)
3. Description keywords (downstream, mirror, fork of, vendored)

**Output**:
- Color-coded detection results
- Reason for each detection
- Sorted, deduplicated list
- Ready for use in `go-version-repo-blocklist.txt`

---

## Cache Management Scripts

All lookup scripts share a centralized set of cache files located in `scripts/caches/`. This improves efficiency by avoiding redundant GitHub API calls across different scripts.

### Shared Cache Files

The following cache files are shared across all lookup scripts:

| File | Purpose |
|------|---------|
| `caches/forks.txt` | Fork repositories (skipped because they sync with upstream) |
| `caches/abandoned.txt` | Repositories with no commits in 6+ months |
| `caches/no-gomod.txt` | Repositories without a go.mod file |

These files are automatically updated by the lookup scripts when they discover new entries, and can be bulk-updated using `update-caches.sh`.

---

### update-caches.sh

**Purpose**: Comprehensive cache update script that refreshes all shared cache files in a single run. Designed for daily automated updates with optional PR creation.

**Features**:
- Scans all configured organizations in one pass
- Updates all three cache files (forks, abandoned, no-gomod)
- Detects changes and reports what would be updated
- Optionally creates a pull request with changes
- Supports dry-run mode for testing

**Usage**:
```bash
# Update all caches
./update-caches.sh

# Update caches and create a PR if there are changes
./update-caches.sh --create-pr

# Custom inactivity threshold (default: 180 days)
./update-caches.sh --days 365

# Dry run - show what would change without making changes
./update-caches.sh --dry-run

# Show help
./update-caches.sh --help
```

**Output**:
- Per-organization scan results
- Summary of cache changes (old count → new count)
- Updated cache files in `scripts/caches/`
- Optional pull request with changes

**CI/CD Integration Example**:
```yaml
# .github/workflows/update-caches.yml
name: Daily Cache Update
on:
  schedule:
    - cron: '0 6 * * *'  # Daily at 6am UTC
  workflow_dispatch:

jobs:
  update-caches:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Update caches and create PR
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: ./scripts/update-caches.sh --create-pr
```

---

### update-fork-cache.sh

**Purpose**: Standalone script for updating just the fork cache. Useful when you need to specifically target fork detection.

**Features**:
- Scans all configured organizations
- Identifies forks via GitHub API
- Optionally closes Go version issues on forks
- Updates `scripts/caches/forks.txt`

**Usage**:
```bash
# Update fork cache
./update-fork-cache.sh

# Update cache and close issues on forks
./update-fork-cache.sh --close-issues

# Show help
./update-fork-cache.sh --help
```

**Output**:
- List of fork repositories with parent info
- Per-organization summary
- Updated cache file
- Optional issue closure report

---

### update-abandoned-repo-cache.sh

**Purpose**: Standalone script for updating just the abandoned repository cache.

**Features**:
- Checks last commit date on default branch
- Configurable inactivity threshold
- Optionally closes issues on abandoned repos
- Updates `scripts/caches/abandoned.txt`

**Usage**:
```bash
# Find repos with no commits in 365 days
./update-abandoned-repo-cache.sh

# Close issues on abandoned repos
./update-abandoned-repo-cache.sh --close-issues

# Custom inactivity threshold (180 days)
./update-abandoned-repo-cache.sh --days 180

# Combine options
./update-abandoned-repo-cache.sh --days 180 --close-issues

# Show help
./update-abandoned-repo-cache.sh --help
```

**Output**:
- Last commit date for each repo
- Active vs. abandoned classification
- Per-organization summary
- Updated cache file
- Optional issue closure report

---

## Notification Scripts

### send-slack-msg.sh

**Purpose**: Sends DCI (Distributed CI) certsuite usage statistics to Slack, including version breakdowns and OCP version testing data.

**Features**:
- Aggregates certsuite version usage
- Tracks runs by commit vs. semantic version
- Reports OCP versions tested against
- Sends formatted message to Slack webhook

**Usage**:
```bash
./send-slack-msg.sh <SLACK_WEBHOOK_URL> <JSON_FILE> <OCP_VERSION_FILE> <DAYS_BACK>
```

**Arguments**:
1. `SLACK_WEBHOOK_URL` - Slack incoming webhook URL
2. `JSON_FILE` - DCI job data (JSON format)
3. `OCP_VERSION_FILE` - OCP version statistics (JSON format)
4. `DAYS_BACK` - Number of days covered in report

**Dependencies**:
- `jq` - JSON processing
- `curl` - HTTP requests

**Example**:
```bash
./send-slack-msg.sh "https://hooks.slack.com/..." dci-data.json ocp-versions.json 30
```

**Message Format**:
```
There have been 150 DCI jobs that have used the certsuite in the last 30 days.

Version: v4.2.0 -- Run Count: 85
Version: v4.1.5 -- Run Count: 45

There have been 20 runs by commit hash.

The following OCP versions have been tested against in the last 30 days:
OCP Version: 4.14 -- Run Count: 90
OCP Version: 4.13 -- Run Count: 60
```

---

### quay-stats-msg.sh

**Purpose**: Sends Quay.io image pull statistics to Slack, tracking usage of legacy and current container images.

**Features**:
- Aggregates pull_repo job counts
- Compares legacy vs. current image usage
- Sends formatted message to Slack

**Usage**:
```bash
./quay-stats-msg.sh <SLACK_WEBHOOK_URL> <JSON_FILE_LEGACY> <JSON_FILE_CURRENT> \
                    <START_DATE> <END_DATE> <REPO_NAME_LEGACY> <REPO_NAME_CURRENT>
```

**Arguments**:
1. `SLACK_WEBHOOK_URL` - Slack incoming webhook URL
2. `JSON_FILE_LEGACY` - Legacy image pull data (JSON)
3. `JSON_FILE_CURRENT` - Current image pull data (JSON)
4. `START_DATE` - Report period start
5. `END_DATE` - Report period end
6. `REPO_NAME_LEGACY` - Legacy image name
7. `REPO_NAME_CURRENT` - Current image name

**Dependencies**:
- `jq` - JSON processing
- `curl` - HTTP requests

**Example**:
```bash
./quay-stats-msg.sh "https://hooks.slack.com/..." \
                    legacy-pulls.json current-pulls.json \
                    "2024-01-01" "2024-01-31" \
                    "quay.io/org/legacy-image" "quay.io/org/new-image"
```

---

### send-cnf-team-jira-update.sh

**Purpose**: Sends formatted CNF team Jira issue updates to Slack, including per-user issue lists and team-wide Fix Version summaries.

**Features**:
- Groups issues by assignee
- Aggregates by Fix Version
- Formats for readability in Slack
- Shows status and last updated date

**Usage**:
```bash
./send-cnf-team-jira-update.sh <SLACK_WEBHOOK_URL> <JSON_FILE>
```

**Arguments**:
1. `SLACK_WEBHOOK_URL` - Slack incoming webhook URL
2. `JSON_FILE` - Sanitized Jira data (output from sanitize-raw-jira-format.sh)

**Dependencies**:
- `jq` - JSON processing
- `curl` - HTTP requests

**Input Format**: Use `sanitize-raw-jira-format.sh` to prepare the JSON file.

**Example**:
```bash
# First, sanitize the raw Jira data
./sanitize-raw-jira-format.sh raw-jira.json sanitized-jira.json

# Then send to Slack
./send-cnf-team-jira-update.sh "https://hooks.slack.com/..." sanitized-jira.json
```

**Message Format**:
```
John Doe (5 issues assigned):
https://issues.redhat.com/browse/PROJ-123 (v1.2) - Status: In Progress - Last Updated: 2024-01-15
https://issues.redhat.com/browse/PROJ-124 (v1.2) - Status: To Do - Last Updated: 2024-01-14
...

Jane Smith (3 issues assigned):
...

Team Issue Totals by Fix Version:
- v1.2: 8 issues
- v1.3: 5 issues
- No Fix Version: 2 issues
```

---

### sanitize-raw-jira-format.sh

**Purpose**: Transforms raw Jira API response data into a clean, structured format for use by other scripts.

**Features**:
- Filters out closed issues
- Excludes unassigned issues
- Groups issues by assignee
- Extracts key fields (summary, status, priority, fixVersion)
- Adds direct URLs to issues

**Usage**:
```bash
./sanitize-raw-jira-format.sh <INPUT_JSON_FILE> <OUTPUT_JSON_FILE>
```

**Arguments**:
1. `INPUT_JSON_FILE` - Raw Jira API response (JSON array)
2. `OUTPUT_JSON_FILE` - Sanitized output file path

**Dependencies**:
- `jq` - JSON processing

**Example**:
```bash
# Fetch raw Jira data (example using curl)
curl -u user:token "https://jira.example.com/rest/api/2/search?jql=..." > raw-jira.json

# Sanitize the data
./sanitize-raw-jira-format.sh raw-jira.json clean-jira.json
```

**Output Format**:
```json
[
  {
    "user": "John Doe",
    "email": "jdoe@example.com",
    "issues": [
      {
        "key": "PROJ-123",
        "summary": "Issue summary",
        "status": "In Progress",
        "priority": "High",
        "created": "2024-01-01T10:00:00.000+0000",
        "updated": "2024-01-15T14:30:00.000+0000",
        "url": "https://issues.redhat.com/browse/PROJ-123",
        "fixVersion": "v1.2"
      }
    ]
  }
]
```

---

## Configuration Files

### go-version-repo-list.txt

Optional list of individual repositories to scan for Go version checking. One repository per line.

**Supported Formats**:
```
owner/repo
github.com/owner/repo
https://github.com/owner/repo
```

**Example**:
```
kubernetes/kubernetes
openshift/origin
redhat-best-practices-for-k8s/certsuite
```

---

### go-version-repo-blocklist.txt

List of repositories to exclude from Go version scanning (e.g., downstream forks, mirrors).

**Supported Formats**: Same as `go-version-repo-list.txt`

**Comments**: Lines starting with `#` or `//` are ignored.

**Example**:
```
# Downstream forks - sync with upstream
openshift/prometheus
openshift/grafana
openshift/thanos

# Archived projects
org/legacy-project
```

---

### gomock-repo-list.txt

Optional list of individual repositories to scan for golang/mock usage.

**Format**: Same as `go-version-repo-list.txt`

---

### golangci-lint-repo-list.txt

Optional list of individual repositories to scan for golangci-lint version checking.

**Format**: Same as `go-version-repo-list.txt`

---

### golangci-lint-repo-blocklist.txt

List of repositories to exclude from golangci-lint version scanning.

**Format**: Same as `go-version-repo-blocklist.txt`

**Comments**: Lines starting with `#` or `//` are ignored.

---

### xcrypto-repo-list.txt

Optional list of individual repositories to scan for x/crypto usage.

**Format**: Same as `go-version-repo-list.txt`

---

### tls13-repo-blocklist.txt

List of repositories to exclude from TLS 1.3 compliance scanning.

**Format**: Same as `go-version-repo-blocklist.txt`

**Comments**: Lines starting with `#` or `//` are ignored.

---

### ubi-repo-list.txt

Optional list of individual repositories to scan for UBI image usage.

**Format**: Same as `go-version-repo-list.txt`

---

## Common Patterns

### Prerequisites Check
All scripts include checks for required tools:
```bash
# Example from any script
./go-version-checker.sh
# Output:
# 🔧 Checking GitHub CLI installation...
# ✅ GitHub CLI is installed
# 🔒 Checking GitHub CLI authentication...
# ✅ GitHub CLI authenticated successfully
```

### Help Documentation
All major scripts support `--help`:
```bash
./go-version-checker.sh --help
./ubi-lookup.sh --help
./find-downstream-repos.sh --help
```

### Cache Files
All lookup scripts share centralized cache files in `scripts/caches/`:

| File | Purpose |
|------|---------|
| `scripts/caches/forks.txt` | Fork repositories (skipped in all scans) |
| `scripts/caches/abandoned.txt` | Repositories inactive for 6+ months |
| `scripts/caches/no-gomod.txt` | Repositories without go.mod files |

Script-specific caches:
- `.ioutil-checker-results.json` - JSON cache of io/ioutil scan results (6-hour lifetime)
- `.tls13-checker-results.json` - JSON cache of TLS compliance scan results (6-hour lifetime)

These shared caches improve performance across all scripts. When a script discovers a new entry (e.g., a new fork or a repo without go.mod), it automatically adds it to the shared cache for all scripts to benefit from.

To refresh all caches, run:
```bash
./scripts/update-caches.sh
```

Use `--clear-cache` or `--force` where supported to force a full rescan ignoring cached data.

### Color-Coded Output
All scripts use consistent color coding:
- 🟢 Green: Success, up-to-date, found
- 🔴 Red: Outdated, errors, issues
- 🔵 Blue: Information, progress
- 🟡 Yellow: Warnings, skipped items

---

## Integration Examples

### CI/CD Pipeline Integration

**Weekly Go Version Check**:
```yaml
# .github/workflows/go-version-check.yml
name: Go Version Check
on:
  schedule:
    - cron: '0 9 * * 1' # Every Monday at 9am UTC
  workflow_dispatch:

jobs:
  check-go-versions:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run Go version checker
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          ./scripts/go-version-checker.sh --create-issues
```

**Daily Cache Update with PR Creation**:
```yaml
# .github/workflows/update-caches.yml
name: Update Repository Caches
on:
  schedule:
    - cron: '0 6 * * *' # Daily at 6am UTC
  workflow_dispatch:

jobs:
  update-caches:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Update all caches and create PR if changed
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: ./scripts/update-caches.sh --create-pr
```

---

## Troubleshooting

### GitHub API Rate Limiting
If you encounter rate limiting issues:
1. Ensure you're authenticated with `gh auth login`
2. Use a GitHub token with appropriate permissions
3. Consider reducing the `LIMIT` variable in scripts
4. Spread scans across different times

### Script Permissions
If you get "Permission denied":
```bash
chmod +x scripts/*.sh
```

### Missing Dependencies
Install required tools:
```bash
# macOS
brew install gh jq

# Fedora/RHEL
sudo dnf install gh jq

# Ubuntu/Debian
sudo apt install gh jq
```

### Cache Issues
If caches seem stale or corrupted:
```bash
# Remove all shared cache files
rm -f scripts/caches/*.txt

# Refresh all caches from GitHub
./scripts/update-caches.sh

# Or use --clear-cache flag where available
./scripts/go-version-checker.sh --clear-cache
```

---

## Best Practices

1. **Run scans during off-peak hours** to minimize impact on GitHub API
2. **Review blocklists regularly** to ensure accurate scanning
3. **Update caches periodically** using the cache management scripts
4. **Monitor tracking issues** in telco-bot repository for high-level status
5. **Use `--help` flags** to understand script options before running
6. **Test scripts on single orgs** before running across all organizations
7. **Keep scripts updated** with the latest patterns and detection logic

---

## Contributing

When contributing new scripts:

1. **Include comprehensive header documentation** with:
   - Description
   - Prerequisites
   - Usage examples
   - Configuration options
   - Output description
   - Limitations

2. **Add help flag support**:
   ```bash
   if [ "$arg" = "--help" ] || [ "$arg" = "-h" ]; then
       # Display help
   fi
   ```

3. **Perform prerequisite checks**:
   ```bash
   if ! command -v gh &>/dev/null; then
       echo "❌ ERROR: GitHub CLI is not installed!"
       exit 1
   fi
   ```

4. **Use consistent terminal colors**:
   ```bash
   GREEN="\033[0;32m"
   RED="\033[0;31m"
   BLUE="\033[0;34m"
   YELLOW="\033[0;33m"
   BOLD="\033[1m"
   RESET="\033[0m"
   ```

5. **Update this README** with detailed documentation for the new script

---

## Support

For issues or questions:
1. Check script's `--help` output
2. Review this documentation
3. Check the main [README.md](../README.md)
4. Open an issue in the telco-bot repository

