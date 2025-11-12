# Telco-Bot

Automation and monitoring toolset for the Red Hat Telco team, providing GitHub repository scanning, dependency tracking, and Slack/Jira integrations.

## Overview

Telco-Bot is a collection of automation tools and scripts designed to help the Red Hat Telco team manage and monitor their GitHub repositories, track dependencies, and stay informed about project health across multiple organizations.

## Features

### Repository Scanning & Monitoring
- **Go Version Tracking**: Automatically scans repositories for outdated Go versions and creates/updates GitHub issues
- **Dependency Monitoring**: Tracks usage of deprecated packages (golang/mock) and security-sensitive dependencies (x/crypto)
- **Container Image Scanning**: Identifies UBI (Universal Base Image) versions across Dockerfiles
- **Repository Health**: Identifies abandoned repositories and forks to prevent unnecessary maintenance

### Integrations
- **GitHub Issues**: Automated issue creation and tracking for outdated dependencies
- **Slack Notifications**: DCI job statistics, Quay image pull metrics, and Jira updates
- **Jira Integration**: Team issue tracking and reporting

### Supported Organizations
- `redhat-best-practices-for-k8s`
- `openshift`
- `openshift-kni`
- `redhat-openshift-ecosystem`
- `redhatci`

## Quick Start

### Prerequisites
- [GitHub CLI (gh)](https://cli.github.com/) - authenticated with appropriate permissions
- `curl`, `jq` - for data processing
- `bash` - version 3.x or higher

### Running Scripts

All automation scripts are located in the `scripts/` directory. Each script includes comprehensive help documentation:

```bash
# View help for any script
./scripts/go-version-checker.sh --help

# Example: Check for outdated Go versions
./scripts/go-version-checker.sh

# Example: Scan for deprecated golang/mock usage
./scripts/gomock-lookup.sh

# Example: Find UBI7 usage across organizations
./scripts/ubi-lookup.sh --version ubi7
```

## Documentation

- [Scripts Documentation](scripts/README.md) - Detailed documentation for all automation scripts
- [Main Scripts](#scripts-overview) - Quick reference for available tools

## Scripts Overview

| Script | Purpose |
|--------|---------|
| `go-version-checker.sh` | Scan for outdated Go versions and create tracking issues |
| `gomock-lookup.sh` | Find repositories using deprecated golang/mock package |
| `xcrypto-lookup.sh` | Identify golang.org/x/crypto usage |
| `ubi-lookup.sh` | Scan for specific UBI image versions in Dockerfiles |
| `find-downstream-repos.sh` | Identify downstream forks and mirrors |
| `update-fork-cache.sh` | Update cache of fork repositories |
| `update-abandoned-repo-cache.sh` | Find and cache abandoned repositories |
| `send-slack-msg.sh` | Send DCI certsuite statistics to Slack |
| `quay-stats-msg.sh` | Send Quay image pull statistics to Slack |
| `send-cnf-team-jira-update.sh` | Send Jira team updates to Slack |
| `sanitize-raw-jira-format.sh` | Format raw Jira data for processing |

## Development

The repository includes a basic Go-based Slack bot framework (`main.go`) that can be extended for interactive queries and automated responses.

### Building
```bash
make build
```

## Contributing

When adding new scripts:
1. Include comprehensive header documentation
2. Add `--help` flag support
3. Include prerequisite checks
4. Update the scripts/README.md with detailed information
5. Use consistent terminal colors for output

## License

See repository license for details.

## Related Projects

- [certsuite](https://github.com/redhat-best-practices-for-k8s/certsuite) - CNF Certification Suite