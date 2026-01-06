#!/bin/bash

#===============================================================================
# GOLANG.ORG/X/CRYPTO USAGE SCANNER
#===============================================================================
#
# DESCRIPTION:
#   This script scans GitHub organizations for repositories that directly use
#   the golang.org/x/crypto package. It identifies Go projects with direct
#   dependencies (excluding indirect dependencies) by examining go.mod files.
#
# PREREQUISITES:
#   1. GitHub CLI (gh) must be installed on your system
#      - Install: https://cli.github.com/
#      - macOS: brew install gh
#      - Linux: See https://github.com/cli/cli/blob/trunk/docs/install_linux.md
#   2. GitHub CLI must be authenticated with sufficient permissions
#      - Run: gh auth login
#      - Requires read access to repositories in target organizations
#   3. curl must be available (typically pre-installed on most systems)
#   4. Internet connection to fetch repository data and go.mod files
#
# USAGE:
#   ./xcrypto-lookup.sh
#
# TRACKING ISSUE:
#   The script maintains a central tracking issue in the telco-bot repo
#   (https://github.com/redhat-best-practices-for-k8s/telco-bot/issues)
#   titled "Tracking golang.org/x/crypto Direct Usage". This issue is
#   automatically created if it doesn't exist and updated with each run.
#
# CONFIGURATION:
#   You can customize which organizations to scan by editing the ORGS array
#   below (line ~85). Add or remove organization names as needed:
#
#   ORGS=("your-org" "another-org" "third-org")
#
#   You can also specify individual repositories in xcrypto-repo-list.txt
#   (one per line). Supported formats:
#     - owner/repo
#     - github.com/owner/repo
#     - https://github.com/owner/repo
#
# OUTPUT:
#   The script provides:
#   - Real-time progress as it scans each repository
#   - Per-organization summary of findings
#   - Final summary with total counts and usage percentage
#   - Color-coded output for easy reading
#   - Table format output showing all repositories using x/crypto directly
#   - Markdown report file (xcrypto-usage-report.md)
#   - Automatic creation/update of central tracking issue in telco-bot repo
#
# LIMITATIONS:
#   - Limited to 1000 repositories per organization (configurable via LIMIT)
#   - Only detects direct dependencies, not transitive usage
#   - Requires public access to go.mod files or appropriate permissions
#===============================================================================

# Terminal colors
GREEN="\033[0;32m"
RED="\033[0;31m"
BLUE="\033[0;34m"
YELLOW="\033[0;33m"
BOLD="\033[1m"
RESET="\033[0m"

#===============================================================================
# HELP MENU
#===============================================================================

show_help() {
	echo -e "${BOLD}GOLANG.ORG/X/CRYPTO USAGE SCANNER${RESET}"
	echo
	echo -e "${BOLD}USAGE:${RESET}"
	echo "    $(basename "$0") [OPTIONS]"
	echo
	echo -e "${BOLD}DESCRIPTION:${RESET}"
	echo "    Scans GitHub organizations for repositories that directly use the"
	echo "    golang.org/x/crypto package. Identifies Go projects with direct"
	echo "    dependencies (excluding indirect) by examining go.mod files."
	echo
	echo -e "${BOLD}OPTIONS:${RESET}"
	echo "    -h, --help          Show this help message and exit"
	echo "    --create-issues     Create tracking issues in repos using outdated x/crypto"
	echo "                        and close issues when repos are up-to-date"
	echo "    -i, --interactive   Prompt before creating, updating, or closing issues"
	echo "                        (requires --create-issues)"
	echo
	echo -e "${BOLD}PREREQUISITES:${RESET}"
	echo "    • GitHub CLI (gh) must be installed and authenticated"
	echo "      Install: brew install gh (macOS) or https://cli.github.com/"
	echo "      Auth: gh auth login"
	echo
	echo -e "${BOLD}CONFIGURATION:${RESET}"
	echo "    Organizations scanned:"
	echo "        redhat-best-practices-for-k8s, openshift, openshift-kni,"
	echo "        redhat-openshift-ecosystem, redhatci"
	echo
	echo "    Individual repositories can be added to xcrypto-repo-list.txt"
	echo "    (one per line, supports: owner/repo, github.com/owner/repo, or full URL)"
	echo
	echo -e "${BOLD}OUTPUT:${RESET}"
	echo "    • Real-time progress and per-organization summaries"
	echo "    • Table showing all repos using x/crypto with version status"
	echo "    • Markdown report: xcrypto-usage-report.md"
	echo "    • Auto-updates tracking issue in telco-bot repo"
	echo
	echo -e "${BOLD}CACHES:${RESET}"
	echo "    Uses shared caches to skip known forks, abandoned repos, and"
	echo "    repos without go.mod files. Caches are stored in:"
	echo "        scripts/caches/"
	echo
	echo -e "${BOLD}ISSUE BLOCKLIST:${RESET}"
	echo "    Repos that don't want tracking issues can be added to:"
	echo "        scripts/caches/xcrypto-issue-blocklist.txt"
	echo "    Format: one repo per line (e.g., openshift/hive)"
	echo
	echo -e "${BOLD}SLACK NOTIFICATIONS:${RESET}"
	echo "    Set XCRYPTO_SLACK_WEBHOOK environment variable to enable"
	echo "    Slack notifications after each scan."
	echo
	echo -e "${BOLD}EXAMPLES:${RESET}"
	echo "    # Run the scanner"
	echo "    ./$(basename "$0")"
	echo
	echo "    # Run scanner and create/manage tracking issues in repos"
	echo "    ./$(basename "$0") --create-issues"
	echo
	echo "    # Interactive mode - prompt before each issue action"
	echo "    ./$(basename "$0") --create-issues -i"
	echo
	echo "    # Show this help"
	echo "    ./$(basename "$0") -h"
	echo
	exit 0
}

# Feature flags
CREATE_ISSUES=false
INTERACTIVE=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
	case $1 in
	-h | --help)
		show_help
		;;
	--create-issues)
		CREATE_ISSUES=true
		;;
	-i | --interactive)
		INTERACTIVE=true
		;;
	*)
		echo -e "${RED}Unknown option: $1${RESET}"
		echo "Use -h or --help for usage information"
		exit 1
		;;
	esac
	shift
done

# Interactive mode requires --create-issues
if [ "$INTERACTIVE" = "true" ] && [ "$CREATE_ISSUES" != "true" ]; then
	echo -e "${YELLOW}⚠️  Warning: --interactive requires --create-issues, enabling it automatically${RESET}"
	CREATE_ISSUES=true
fi

# Check if GitHub CLI is installed
echo "🔧 Checking GitHub CLI installation..."
if ! command -v gh &>/dev/null; then
	echo -e "${RED}❌ ERROR: GitHub CLI (gh) is not installed!${RESET}"
	echo -e "${YELLOW}💡 Please install it first:${RESET}"
	echo -e "${YELLOW}   macOS: brew install gh${RESET}"
	echo -e "${YELLOW}   Linux: https://github.com/cli/cli/blob/trunk/docs/install_linux.md${RESET}"
	echo -e "${YELLOW}   Or visit: https://cli.github.com/${RESET}"
	exit 1
fi
echo -e "${GREEN}✅ GitHub CLI is installed${RESET}"

# Check if GitHub CLI is logged in
echo "🔒 Checking GitHub CLI authentication..."
if ! gh auth status &>/dev/null; then
	echo -e "${RED}❌ ERROR: GitHub CLI is not logged in!${RESET}"
	echo -e "${YELLOW}💡 Please run 'gh auth login' to authenticate first.${RESET}"
	exit 1
fi
echo -e "${GREEN}✅ GitHub CLI authenticated successfully${RESET}"
echo

# List of orgs to scan
ORGS=("redhat-best-practices-for-k8s" "openshift" "openshift-kni" "redhat-openshift-ecosystem" "redhatci")
# ORGS=("openshift-kni")

LIMIT=1000
FOUND_COUNT=0
TOTAL_REPOS=0
SKIPPED_FORKS=0
SKIPPED_NOGOMOD=0
SKIPPED_ABANDONED=0
ISSUES_CREATED=0
ISSUES_UPDATED=0
ISSUES_CLOSED=0
ISSUES_REOPENED=0

# Get script directory for relative paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Shared cache files (used by all lookup scripts)
CACHE_DIR="$SCRIPT_DIR/caches"
FORK_CACHE="$CACHE_DIR/forks.txt"
NOGOMOD_CACHE="$CACHE_DIR/no-gomod.txt"
ABANDONED_CACHE="$CACHE_DIR/abandoned.txt"
XCRYPTO_ISSUE_BLOCKLIST="$CACHE_DIR/xcrypto-issue-blocklist.txt"
OUTPUT_MD="xcrypto-usage-report.md"

# Ensure cache directory exists
mkdir -p "$CACHE_DIR"

# Inactivity threshold (in days)
INACTIVITY_DAYS=180 # 6 months

# Create empty cache files if they don't exist
touch "$FORK_CACHE" "$NOGOMOD_CACHE" "$ABANDONED_CACHE"

#===============================================================================
# HELPER FUNCTIONS
#===============================================================================

# Helper function for interactive confirmation
# Returns 0 (true) if user confirms, 1 (false) if declined
# In non-interactive mode, always returns 0
confirm_action() {
	local action="$1"
	local repo="$2"
	local details="$3"

	# Skip confirmation if not in interactive mode
	if [ "$INTERACTIVE" != "true" ]; then
		return 0
	fi

	echo
	echo -e "${BOLD}${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
	echo -e "${BOLD}Action:${RESET} ${action}"
	echo -e "${BOLD}Repository:${RESET} ${repo}"
	if [ -n "$details" ]; then
		echo -e "${BOLD}Details:${RESET} ${details}"
	fi
	echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
	echo -ne "${BOLD}Proceed? [y/N]: ${RESET}"

	# Read from /dev/tty to get input from terminal even when stdin is redirected
	read -r response </dev/tty
	case "$response" in
	[yY] | [yY][eE][sS])
		return 0
		;;
	*)
		echo -e "${BLUE}Skipped${RESET}"
		return 1
		;;
	esac
}

# Helper function to check if repo is in cache
is_in_cache() {
	local repo="$1"
	local cache_file="$2"
	grep -Fxq "$repo" "$cache_file" 2>/dev/null
}

# Helper function to check if repo is abandoned (no commits in last 6 months)
is_repo_abandoned() {
	local repo="$1"
	local branch="$2"

	# Fetch last commit date from default branch
	local last_commit=$(gh api "repos/${repo}/commits/${branch}" --jq '.commit.committer.date' 2>/dev/null)

	if [[ $? -ne 0 || -z "$last_commit" ]]; then
		# Unable to fetch commit date, don't mark as abandoned
		return 1
	fi

	# Compare dates
	if [ "$last_commit" \< "$CUTOFF_DATE" ]; then
		# Repo is abandoned
		return 0
	else
		# Repo is active
		return 1
	fi
}

# Helper function to extract x/crypto version from go.mod content
# Returns the version string (e.g., v0.21.0) or "unknown"
extract_xcrypto_version() {
	local go_mod_content="$1"

	# Look for golang.org/x/crypto version (direct dependency, not indirect)
	# Handle both single-line require and require block formats
	local version=$(echo "$go_mod_content" | grep 'golang.org/x/crypto' | grep -v '// indirect' | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)

	if [ -n "$version" ]; then
		echo "$version"
	else
		echo "unknown"
	fi
}

# Helper function to compare semver versions
# Returns: "current" if same, "outdated" if behind, "ahead" if ahead, "unknown" if can't compare
compare_versions() {
	local current="$1"
	local latest="$2"

	# Remove 'v' prefix for comparison
	current="${current#v}"
	latest="${latest#v}"

	if [ "$current" = "$latest" ]; then
		echo "current"
		return
	fi

	# Split into major.minor.patch
	IFS='.' read -r cur_major cur_minor cur_patch <<<"$current"
	IFS='.' read -r lat_major lat_minor lat_patch <<<"$latest"

	# Compare major
	if [ "$cur_major" -lt "$lat_major" ] 2>/dev/null; then
		echo "outdated"
		return
	elif [ "$cur_major" -gt "$lat_major" ] 2>/dev/null; then
		echo "ahead"
		return
	fi

	# Compare minor
	if [ "$cur_minor" -lt "$lat_minor" ] 2>/dev/null; then
		echo "outdated"
		return
	elif [ "$cur_minor" -gt "$lat_minor" ] 2>/dev/null; then
		echo "ahead"
		return
	fi

	# Compare patch
	if [ "$cur_patch" -lt "$lat_patch" ] 2>/dev/null; then
		echo "outdated"
		return
	elif [ "$cur_patch" -gt "$lat_patch" ] 2>/dev/null; then
		echo "ahead"
		return
	fi

	echo "current"
}

# Helper function to check if a repo has Dependabot configured
# Returns: "yes" if dependabot.yml/yaml exists, "no" otherwise
check_dependabot() {
	local repo="$1"
	local branch="$2"

	# Check for dependabot.yml
	local yml_url="https://raw.githubusercontent.com/$repo/$branch/.github/dependabot.yml"
	if curl -s -f -o /dev/null "$yml_url" 2>/dev/null; then
		echo "yes"
		return
	fi

	# Check for dependabot.yaml
	local yaml_url="https://raw.githubusercontent.com/$repo/$branch/.github/dependabot.yaml"
	if curl -s -f -o /dev/null "$yaml_url" 2>/dev/null; then
		echo "yes"
		return
	fi

	echo "no"
}

# Issue title for tracking x/crypto updates
XCRYPTO_ISSUE_TITLE="Update golang.org/x/crypto to address security vulnerabilities"

# Helper function to compare if patched_version > current_version
# Returns 0 (true) if patched > current, 1 (false) otherwise
is_patched_version_newer() {
	local current="$1"
	local patched="$2"

	# Remove 'v' prefix if present
	current="${current#v}"
	patched="${patched#v}"

	# Pseudo-versions (0.0.0-timestamp-hash) are always older than real semver
	# If patched starts with "0.0.0-", it's a pseudo-version
	if [[ "$patched" == 0.0.0-* ]]; then
		# Pseudo-version - these are older than any real semver like 0.1.0+
		# If current is also a pseudo-version, compare timestamps
		if [[ "$current" == 0.0.0-* ]]; then
			# Compare the timestamp portion (after first dash)
			local current_ts=$(echo "$current" | cut -d'-' -f2)
			local patched_ts=$(echo "$patched" | cut -d'-' -f2)
			[[ "$patched_ts" > "$current_ts" ]]
			return $?
		else
			# Current is real semver, patched is pseudo-version = patched is older
			return 1
		fi
	fi

	# If current is pseudo-version but patched is real semver, patched is newer
	if [[ "$current" == 0.0.0-* ]]; then
		return 0
	fi

	# Both are real semver - compare major.minor.patch
	IFS='.' read -r cur_major cur_minor cur_patch <<<"$current"
	IFS='.' read -r pat_major pat_minor pat_patch <<<"$patched"

	# Remove any suffix from patch (e.g., "0-rc1" -> "0")
	cur_patch="${cur_patch%%-*}"
	pat_patch="${pat_patch%%-*}"

	# Compare major
	if [ "${pat_major:-0}" -gt "${cur_major:-0}" ] 2>/dev/null; then
		return 0
	elif [ "${pat_major:-0}" -lt "${cur_major:-0}" ] 2>/dev/null; then
		return 1
	fi

	# Compare minor
	if [ "${pat_minor:-0}" -gt "${cur_minor:-0}" ] 2>/dev/null; then
		return 0
	elif [ "${pat_minor:-0}" -lt "${cur_minor:-0}" ] 2>/dev/null; then
		return 1
	fi

	# Compare patch
	if [ "${pat_patch:-0}" -gt "${cur_patch:-0}" ] 2>/dev/null; then
		return 0
	fi

	return 1
}

# Helper function to fetch CVEs affecting x/crypto versions
# Queries GitHub's Security Advisory database for golang.org/x/crypto
# Returns a formatted list of CVEs fixed in versions AFTER the current version
# Returns "FETCH_FAILED" if the API call fails after retries
fetch_xcrypto_cves() {
	local current_version="$1"
	local max_retries=3
	local retry_delay=2
	local attempt=1
	local advisories=""
	local api_exit_code=0

	# Retry loop with exponential backoff
	while [ $attempt -le $max_retries ]; do
		# Query GitHub's Security Advisory API for golang.org/x/crypto
		# This fetches all advisories that affect the golang.org/x/crypto package
		advisories=$(gh api graphql -f query='
			query {
				securityVulnerabilities(ecosystem: GO, package: "golang.org/x/crypto", first: 50) {
					nodes {
						advisory {
							ghsaId
							summary
							severity
							publishedAt
							permalink
							identifiers {
								type
								value
							}
						}
						vulnerableVersionRange
						firstPatchedVersion {
							identifier
						}
					}
				}
			}
		' 2>&1)
		api_exit_code=$?

		# Check if API call succeeded and returned valid data
		if [ $api_exit_code -eq 0 ] && [ -n "$advisories" ] && [ "$advisories" != "null" ] && echo "$advisories" | grep -q "securityVulnerabilities"; then
			break # Success, exit retry loop
		fi

		# Log retry attempt (only if not the last attempt)
		if [ $attempt -lt $max_retries ]; then
			echo "  (CVE fetch attempt $attempt failed, retrying in ${retry_delay}s...)" >&2
			sleep $retry_delay
			retry_delay=$((retry_delay * 2)) # Exponential backoff
		fi
		attempt=$((attempt + 1))
	done

	# After all retries, check if we have valid data
	if [ $api_exit_code -ne 0 ] || [ -z "$advisories" ] || [ "$advisories" = "null" ] || ! echo "$advisories" | grep -q "securityVulnerabilities"; then
		echo "FETCH_FAILED"
		return 1
	fi

	# Parse CVEs into a temp file, then filter by version
	local cve_lines=$(echo "$advisories" | jq -r '
		.data.securityVulnerabilities.nodes[] |
		select(.firstPatchedVersion.identifier != null) |
		{
			cve: (.advisory.identifiers[] | select(.type == "CVE") | .value) // .advisory.ghsaId,
			ghsa: .advisory.ghsaId,
			summary: .advisory.summary,
			severity: .advisory.severity,
			patched: .firstPatchedVersion.identifier,
			range: .vulnerableVersionRange,
			url: .advisory.permalink
		} |
		"\(.patched)|\(.cve // .ghsa)|\(.severity)|\(.summary)|\(.url)"
	' 2>/dev/null | sort -u)

	# Filter to only include CVEs where patched version > current version
	local result=""
	while IFS='|' read -r patched cve severity summary url; do
		[ -z "$patched" ] && continue

		# Only include if the fix version is newer than what the repo is using
		if is_patched_version_newer "$current_version" "$patched"; then
			result+="- **${cve}** (${severity}): ${summary} - Fixed in \`${patched}\` ([details](${url}))"$'\n'
		fi
	done <<<"$cve_lines"

	echo "$result"
}

# Helper function to check if a tracking issue exists in a repo
# Returns: issue number if exists, empty string otherwise
find_xcrypto_issue() {
	local repo="$1"

	# Search for our specific issue title
	gh issue list --repo "$repo" \
		--search "in:title \"${XCRYPTO_ISSUE_TITLE}\"" \
		--state all \
		--json number,title,state \
		--jq ".[] | select(.title == \"${XCRYPTO_ISSUE_TITLE}\") | .number" \
		2>/dev/null | head -1
}

# Helper function to get the state of an issue
get_issue_state() {
	local repo="$1"
	local issue_number="$2"

	gh issue view "$issue_number" --repo "$repo" --json state --jq '.state' 2>/dev/null
}

# Helper function to build the issue body for x/crypto tracking issues
# This is used by both create and update functions to ensure consistency
build_xcrypto_issue_body() {
	local current_version="$1"
	local latest_version="$2"
	local has_dependabot="$3"
	local cve_list="$4"

	local issue_body="## ⚠️ Outdated golang.org/x/crypto Dependency

This repository is currently using **\`golang.org/x/crypto ${current_version}\`** but the latest version is **\`${latest_version}\`**.

> **Last scanned:** $(date -u '+%Y-%m-%d %H:%M UTC')

### Why Update?

Keeping cryptographic dependencies up-to-date is critical for security. Newer versions often include fixes for known vulnerabilities.
"

	# Add CVE section - either list CVEs or note that there are none
	if [ -n "$cve_list" ]; then
		issue_body+="
### 🔒 Security Vulnerabilities Fixed in Newer Versions

The following CVEs have been addressed in versions after ${current_version}:

${cve_list}

"
	else
		issue_body+="
### ℹ️ No Known CVEs

There are no known CVEs specifically addressed between \`${current_version}\` and \`${latest_version}\`. However, staying current with the latest version is still recommended for:

- Bug fixes and stability improvements
- Compatibility with other updated dependencies
- Proactive security posture

"
	fi

	# Add Dependabot recommendation if not configured
	if [ "$has_dependabot" = "no" ]; then
		issue_body+="
### 🤖 Recommendation: Enable Dependabot

This repository does not appear to have Dependabot configured. We recommend enabling Dependabot to automatically keep your \`go.mod\` dependencies up-to-date and receive security alerts.

To enable Dependabot, create a \`.github/dependabot.yml\` file:

\`\`\`yaml
version: 2
updates:
  - package-ecosystem: \"gomod\"
    directory: \"/\"
    schedule:
      interval: \"weekly\"
    open-pull-requests-limit: 10
\`\`\`

See [GitHub Dependabot documentation](https://docs.github.com/en/code-security/dependabot/dependabot-version-updates/configuring-dependabot-version-updates) for more details.

"
	fi

	issue_body+="
### 📋 How to Update

Run the following command to update:

\`\`\`bash
go get golang.org/x/crypto@${latest_version}
go mod tidy
\`\`\`

Then run your tests and submit a PR with the changes.

### 🔗 Central Tracking

This issue is part of an organization-wide effort to keep \`golang.org/x/crypto\` dependencies up-to-date.

"

	# Add link to central tracking issue if available
	if [ -n "$CENTRAL_TRACKING_ISSUE" ]; then
		issue_body+="**See the central tracking issue for a full overview:** [${TRACKING_REPO}#${CENTRAL_TRACKING_ISSUE}](${CENTRAL_TRACKING_URL})
"
	else
		issue_body+="**Central tracking:** [${TRACKING_REPO}](${CENTRAL_TRACKING_URL})
"
	fi

	issue_body+="
---

*This issue is automatically managed by the [xcrypto-lookup.sh](https://github.com/redhat-best-practices-for-k8s/telco-bot/blob/main/scripts/xcrypto-lookup.sh) scanner.*"

	echo "$issue_body"
}

# Helper function to create a tracking issue for outdated x/crypto
create_xcrypto_issue() {
	local repo="$1"
	local current_version="$2"
	local latest_version="$3"
	local has_dependabot="$4"
	local cve_list="$5"

	local issue_body=$(build_xcrypto_issue_body "$current_version" "$latest_version" "$has_dependabot" "$cve_list")

	# Create the issue
	gh issue create --repo "$repo" \
		--title "$XCRYPTO_ISSUE_TITLE" \
		--body "$issue_body" \
		2>/dev/null
}

# Helper function to update an existing tracking issue with new version/CVE info
update_xcrypto_issue() {
	local repo="$1"
	local issue_number="$2"
	local current_version="$3"
	local latest_version="$4"
	local has_dependabot="$5"
	local cve_list="$6"

	local issue_body=$(build_xcrypto_issue_body "$current_version" "$latest_version" "$has_dependabot" "$cve_list")

	# Update the issue body
	gh issue edit "$issue_number" --repo "$repo" \
		--body "$issue_body" \
		2>/dev/null
}

# Helper function to close a tracking issue (repo is now up-to-date)
close_xcrypto_issue() {
	local repo="$1"
	local issue_number="$2"
	local current_version="$3"

	# Add a comment explaining why we're closing
	gh issue comment "$issue_number" --repo "$repo" \
		--body "✅ **Resolved**: This repository has been updated to \`golang.org/x/crypto ${current_version}\`, which is the latest version. Closing this issue.

---
*Automatically closed by [xcrypto-lookup.sh](https://github.com/redhat-best-practices-for-k8s/telco-bot/blob/main/scripts/xcrypto-lookup.sh)*" \
		2>/dev/null

	# Close the issue
	gh issue close "$issue_number" --repo "$repo" 2>/dev/null
}

# Helper function to reopen a tracking issue (repo was updated but reverted)
reopen_xcrypto_issue() {
	local repo="$1"
	local issue_number="$2"
	local current_version="$3"
	local latest_version="$4"
	local cve_list="$5"

	# Add a comment explaining why we're reopening
	local reopen_comment="⚠️ **Reopened**: This repository is now using \`golang.org/x/crypto ${current_version}\`, which is outdated. The latest version is \`${latest_version}\`.
"

	if [ -n "$cve_list" ]; then
		reopen_comment+="
### Security Vulnerabilities to Address

${cve_list}
"
	fi

	# Add link to central tracking issue
	if [ -n "$CENTRAL_TRACKING_ISSUE" ]; then
		reopen_comment+="
**Central tracking:** [${TRACKING_REPO}#${CENTRAL_TRACKING_ISSUE}](${CENTRAL_TRACKING_URL})
"
	fi

	reopen_comment+="
---
*Automatically reopened by [xcrypto-lookup.sh](https://github.com/redhat-best-practices-for-k8s/telco-bot/blob/main/scripts/xcrypto-lookup.sh)*"

	gh issue reopen "$issue_number" --repo "$repo" 2>/dev/null
	gh issue comment "$issue_number" --repo "$repo" --body "$reopen_comment" 2>/dev/null
}

# Helper function to manage tracking issues for a repository
# Creates, updates, or closes issues based on the repo's x/crypto version status
manage_repo_issue() {
	local repo="$1"
	local current_version="$2"
	local latest_version="$3"
	local version_status="$4"
	local has_dependabot="$5"

	# Reset the global issue URL tracker
	LAST_REPO_ISSUE_URL=""

	# Skip if --create-issues was not specified
	if [ "$CREATE_ISSUES" != "true" ]; then
		return
	fi

	# Skip repos on the blocklist (repos that don't want issue notifications)
	if [ -f "$XCRYPTO_ISSUE_BLOCKLIST" ] && grep -Fxq "$repo" "$XCRYPTO_ISSUE_BLOCKLIST" 2>/dev/null; then
		echo -ne " ${BLUE}(blocklisted - skipping issue mgmt)${RESET}"
		return
	fi

	# Find existing issue
	local existing_issue=$(find_xcrypto_issue "$repo")

	if [ "$version_status" = "outdated" ]; then
		# Fetch CVEs for this version
		local cve_list=$(fetch_xcrypto_cves "$current_version")

		# Check if CVE fetch failed - don't make any issue changes if we can't verify CVE status
		if [ "$cve_list" = "FETCH_FAILED" ]; then
			echo -ne " ${YELLOW}(CVE fetch failed - skipping issue management)${RESET}"
			return
		fi

		# Only create/manage issues if there are CVEs to address
		if [ -n "$cve_list" ]; then
			# There ARE CVEs - create or update the issue
			if [ -n "$existing_issue" ]; then
				# Store the issue URL
				LAST_REPO_ISSUE_URL="https://github.com/${repo}/issues/${existing_issue}"

				# Check if issue is closed
				local issue_state=$(get_issue_state "$repo" "$existing_issue")
				if [ "$issue_state" = "CLOSED" ]; then
					# Reopen the issue and update its body
					if confirm_action "REOPEN issue #${existing_issue}" "$repo" "CVEs found: ${current_version} → ${latest_version}"; then
						echo -ne " ${YELLOW}(reopening #${existing_issue} - CVEs found)${RESET}"
						if reopen_xcrypto_issue "$repo" "$existing_issue" "$current_version" "$latest_version" "$cve_list"; then
							ISSUES_REOPENED=$((ISSUES_REOPENED + 1))
						fi
						# Also update the issue body with current info
						update_xcrypto_issue "$repo" "$existing_issue" "$current_version" "$latest_version" "$has_dependabot" "$cve_list"
					fi
				else
					# Issue is open - update it with latest version/CVE info
					if confirm_action "UPDATE issue #${existing_issue}" "$repo" "Refresh with latest CVE info"; then
						echo -ne " ${BLUE}(updating #${existing_issue})${RESET}"
						if update_xcrypto_issue "$repo" "$existing_issue" "$current_version" "$latest_version" "$has_dependabot" "$cve_list"; then
							ISSUES_UPDATED=$((ISSUES_UPDATED + 1))
						fi
					fi
				fi
			else
				# Create new issue
				if confirm_action "CREATE new issue" "$repo" "Outdated: ${current_version} → ${latest_version} (CVEs found)"; then
					echo -ne " ${YELLOW}(creating issue - CVEs found)${RESET}"
					local new_issue=$(create_xcrypto_issue "$repo" "$current_version" "$latest_version" "$has_dependabot" "$cve_list")
					if [ -n "$new_issue" ]; then
						local issue_num=$(echo "$new_issue" | grep -oE '[0-9]+$')
						echo -ne " ${GREEN}(#${issue_num})${RESET}"
						ISSUES_CREATED=$((ISSUES_CREATED + 1))
						# Store the issue URL
						LAST_REPO_ISSUE_URL="https://github.com/${repo}/issues/${issue_num}"
					fi
				fi
			fi
		else
			# NO CVEs between versions - close any existing open issue
			if [ -n "$existing_issue" ]; then
				local issue_state=$(get_issue_state "$repo" "$existing_issue")
				if [ "$issue_state" = "OPEN" ]; then
					if confirm_action "CLOSE issue #${existing_issue}" "$repo" "No CVEs between ${current_version} and ${latest_version}"; then
						echo -ne " ${GREEN}(closing #${existing_issue} - no CVEs)${RESET}"
						# Close with a specific message about no CVEs
						gh issue comment "$existing_issue" --repo "$repo" \
							--body "✅ **Closing**: No security vulnerabilities (CVEs) are addressed between \`${current_version}\` and \`${latest_version}\`. While the version is outdated, there are no urgent security reasons to update.

---
*Automatically closed by [xcrypto-lookup.sh](https://github.com/redhat-best-practices-for-k8s/telco-bot/blob/main/scripts/xcrypto-lookup.sh)*" \
							2>/dev/null
						gh issue close "$existing_issue" --repo "$repo" 2>/dev/null
						ISSUES_CLOSED=$((ISSUES_CLOSED + 1))
					fi
				fi
			fi
		fi
	elif [ "$version_status" = "current" ]; then
		if [ -n "$existing_issue" ]; then
			# Check if issue is open
			local issue_state=$(get_issue_state "$repo" "$existing_issue")
			if [ "$issue_state" = "OPEN" ]; then
				# Close the issue - repo is up to date
				if confirm_action "CLOSE issue #${existing_issue}" "$repo" "Repository is now up to date (${current_version})"; then
					echo -ne " ${GREEN}(closing #${existing_issue} - up to date)${RESET}"
					if close_xcrypto_issue "$repo" "$existing_issue" "$current_version"; then
						ISSUES_CLOSED=$((ISSUES_CLOSED + 1))
					fi
				fi
			fi
		fi
	fi
}

#===============================================================================
# LOAD CACHES
#===============================================================================

# Load fork cache info if it exists
FORK_COUNT_LOADED=0
if [ -f "$FORK_CACHE" ] && [ -s "$FORK_CACHE" ]; then
	FORK_COUNT_LOADED=$(wc -l <"$FORK_CACHE" | tr -d ' ')
	echo "📋 Loading fork cache from $FORK_CACHE..."
	echo -e "${GREEN}✓ Loaded ${FORK_COUNT_LOADED} fork repositories to skip${RESET}"
	echo
fi

# Load no-go.mod cache info if it exists
NOGOMOD_COUNT_LOADED=0
if [ -f "$NOGOMOD_CACHE" ] && [ -s "$NOGOMOD_CACHE" ]; then
	NOGOMOD_COUNT_LOADED=$(wc -l <"$NOGOMOD_CACHE" | tr -d ' ')
	echo "📋 Loading no-go.mod cache from $NOGOMOD_CACHE..."
	echo -e "${GREEN}✓ Loaded ${NOGOMOD_COUNT_LOADED} repositories without go.mod to skip${RESET}"
	echo
fi

# Load abandoned repo cache info if it exists
ABANDONED_COUNT_LOADED=0
if [ -f "$ABANDONED_CACHE" ] && [ -s "$ABANDONED_CACHE" ]; then
	ABANDONED_COUNT_LOADED=$(wc -l <"$ABANDONED_CACHE" | tr -d ' ')
	echo "📋 Loading abandoned repo cache from $ABANDONED_CACHE..."
	echo -e "${GREEN}✓ Loaded ${ABANDONED_COUNT_LOADED} abandoned repositories to skip${RESET}"
	echo
fi

# Calculate cutoff date (6 months ago)
CUTOFF_DATE=$(date -u -v-${INACTIVITY_DAYS}d "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "${INACTIVITY_DAYS} days ago" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")

if [ -z "$CUTOFF_DATE" ]; then
	echo -e "${RED}❌ ERROR: Unable to calculate cutoff date${RESET}" >&2
	exit 1
fi

# Temporary file to track newly discovered no-go.mod repos
NOGOMOD_TEMP=$(mktemp)

#===============================================================================
# FETCH LATEST XCRYPTO VERSION
#===============================================================================

echo "🔍 Fetching latest golang.org/x/crypto version from GitHub..."
LATEST_XCRYPTO_VERSION=$(gh api repos/golang/crypto/tags --jq '.[0].name' 2>/dev/null || echo "unknown")

if [ "$LATEST_XCRYPTO_VERSION" = "unknown" ] || [ -z "$LATEST_XCRYPTO_VERSION" ]; then
	echo -e "${YELLOW}⚠️  Could not fetch latest version, version comparison will be skipped${RESET}"
else
	echo -e "${GREEN}✅ Latest golang.org/x/crypto version: ${LATEST_XCRYPTO_VERSION}${RESET}"
fi
echo

# Tracking issue configuration
TRACKING_REPO="redhat-best-practices-for-k8s/telco-bot"
TRACKING_ISSUE_TITLE="Tracking golang.org/x/crypto Direct Usage"

# Look up the central tracking issue number (needed for --create-issues to link back)
CENTRAL_TRACKING_ISSUE=""
if [ "$CREATE_ISSUES" = "true" ]; then
	echo "🔗 Looking up central tracking issue in ${TRACKING_REPO}..."
	CENTRAL_TRACKING_ISSUE=$(gh issue list --repo "$TRACKING_REPO" \
		--search "in:title \"${TRACKING_ISSUE_TITLE}\"" \
		--state all \
		--json number,title \
		--jq ".[] | select(.title == \"${TRACKING_ISSUE_TITLE}\") | .number" \
		2>/dev/null | head -1)

	if [ -n "$CENTRAL_TRACKING_ISSUE" ]; then
		echo -e "${GREEN}✅ Found central tracking issue: #${CENTRAL_TRACKING_ISSUE}${RESET}"
		CENTRAL_TRACKING_URL="https://github.com/${TRACKING_REPO}/issues/${CENTRAL_TRACKING_ISSUE}"
	else
		echo -e "${YELLOW}⚠️  Central tracking issue not found (will be created at end of scan)${RESET}"
		CENTRAL_TRACKING_URL="https://github.com/${TRACKING_REPO}/issues"
	fi
	echo
fi

# Array to store repositories using x/crypto directly
declare -a XCRYPTO_REPOS

# Temporary file to store org-specific data for tracking issue (with last commit date and Dependabot status)
ORG_DATA_FILE=$(mktemp)

echo -e "${BLUE}${BOLD}🔍 SCANNING REPOSITORIES FOR GOLANG.ORG/X/CRYPTO USAGE${RESET}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${RESET}"
echo -e "${YELLOW}⚠️  Note: Tracking direct dependencies on golang.org/x/crypto${RESET}"
if [ "$CREATE_ISSUES" = "true" ]; then
	echo -e "${GREEN}📋 Issue management: ENABLED (will create/close tracking issues)${RESET}"
fi
echo -e "${BLUE}───────────────────────────────────────────────────────────${RESET}"
echo -e "${BLUE}📅 Skipping repos with no commits since: ${CUTOFF_DATE:0:10}${RESET}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${RESET}"
echo

for ORG_NAME in "${ORGS[@]}"; do
	echo -e "${YELLOW}${BOLD}👉 Organization: ${ORG_NAME}${RESET}"

	# Get all repos first (including fork status)
	echo -e "${BLUE}   Fetching repository list...${RESET}"
	REPOS=$(gh repo list "$ORG_NAME" --limit "$LIMIT" --json nameWithOwner,defaultBranchRef,isArchived,isFork -q '.[] | select(.isArchived == false) | .nameWithOwner + " " + .defaultBranchRef.name + " " + (.isFork | tostring)')
	REPO_COUNT=$(echo "$REPOS" | grep -v '^$' | wc -l | tr -d ' ')

	if [ "$REPO_COUNT" -eq 0 ]; then
		echo -e "${BLUE}   No active repositories found${RESET}"
		echo
		continue
	fi

	TOTAL_REPOS=$((TOTAL_REPOS + REPO_COUNT))

	echo -e "${BLUE}   Found ${REPO_COUNT} active repositories to scan${RESET}"
	echo

	# Track results for this organization
	ORG_FOUND=0

	# Use a separate file to store results to overcome the subshell limitation
	temp_results=$(mktemp)

	while read -r repo branch is_fork; do
		# Skip empty lines
		[[ -z "$repo" ]] && continue

		# Show a simple progress indicator
		echo -ne "   📂 ${repo} on branch ${branch}... "

		# Check if repo is a fork (either from cache or API)
		if is_in_cache "$repo" "$FORK_CACHE" || [ "$is_fork" = "true" ]; then
			echo -e "${BLUE}⏩ skipped (fork)${RESET}"
			SKIPPED_FORKS=$((SKIPPED_FORKS + 1))
			# Add to cache if detected via API but not in cache yet
			if [ "$is_fork" = "true" ] && ! is_in_cache "$repo" "$FORK_CACHE"; then
				echo "$repo" >>"$FORK_CACHE"
			fi
			continue
		fi

		# Check if repo is in abandoned cache
		if is_in_cache "$repo" "$ABANDONED_CACHE"; then
			echo -e "${BLUE}⏩ skipped (abandoned)${RESET}"
			SKIPPED_ABANDONED=$((SKIPPED_ABANDONED + 1))
			continue
		fi

		# Check if repo is abandoned (no commits in last 6 months)
		if is_repo_abandoned "$repo" "$branch"; then
			echo -e "${BLUE}⏩ skipped (abandoned - no recent commits)${RESET}"
			echo "$repo" >>"$ABANDONED_CACHE"
			SKIPPED_ABANDONED=$((SKIPPED_ABANDONED + 1))
			continue
		fi

		# Check if repo is in no-go.mod cache
		if is_in_cache "$repo" "$NOGOMOD_CACHE"; then
			echo -e "${BLUE}⏩ skipped (no go.mod)${RESET}"
			SKIPPED_NOGOMOD=$((SKIPPED_NOGOMOD + 1))
			continue
		fi

		# Fetch go.mod raw content from default branch
		raw_url="https://raw.githubusercontent.com/$repo/$branch/go.mod"
		go_mod=$(curl -s -f "$raw_url")

		if [[ $? -ne 0 ]]; then
			echo -e "${YELLOW}no go.mod (cached)${RESET}"
			echo "$repo" >>"$NOGOMOD_TEMP"
			SKIPPED_NOGOMOD=$((SKIPPED_NOGOMOD + 1))
			continue
		fi

		# Check for direct dependency (exclude // indirect)
		# Matches both: "require golang.org/x/crypto v..." and "	golang.org/x/crypto v..." (inside require block)
		if echo "$go_mod" | grep 'golang.org/x/crypto' | grep -vq '// indirect'; then
			# Extract the version being used
			xcrypto_version=$(extract_xcrypto_version "$go_mod")
			version_status="unknown"

			if [ "$LATEST_XCRYPTO_VERSION" != "unknown" ] && [ "$xcrypto_version" != "unknown" ]; then
				version_status=$(compare_versions "$xcrypto_version" "$LATEST_XCRYPTO_VERSION")
			fi

			# Show version status in terminal output
			if [ "$version_status" = "current" ]; then
				echo -e "${GREEN}✓ USES crypto directly (${xcrypto_version} ✅ current)${RESET}"
			elif [ "$version_status" = "outdated" ]; then
				echo -e "${GREEN}✓ USES crypto directly${RESET} ${YELLOW}(${xcrypto_version} ⚠️  outdated)${RESET}"
			else
				echo -e "${GREEN}✓ USES crypto directly (${xcrypto_version})${RESET}"
			fi

			echo "$repo" >>"$temp_results"
			XCRYPTO_REPOS+=("$repo")

			# Fetch last commit date from default branch for tracking issue
			last_commit=$(gh api "repos/${repo}/commits/${branch}" --jq '.commit.committer.date' 2>/dev/null || echo "unknown")

			# Check if repo has Dependabot configured
			dependabot_status=$(check_dependabot "$repo" "$branch")

			# Manage tracking issue in the repo (create/close based on version status)
			manage_repo_issue "$repo" "$xcrypto_version" "$LATEST_XCRYPTO_VERSION" "$version_status" "$dependabot_status"

			# Store for org-specific data: org|repo|branch|last_commit|dependabot_status|xcrypto_version|issue_url
			echo "$ORG_NAME|$repo|$branch|$last_commit|$dependabot_status|$xcrypto_version|$LAST_REPO_ISSUE_URL" >>"$ORG_DATA_FILE"
		else
			echo -e "${RED}✗ NO direct usage${RESET}"
		fi
	done <<<"$REPOS"

	# Count the results
	if [ -f "$temp_results" ] && [ -s "$temp_results" ]; then
		ORG_FOUND=$(wc -l <"$temp_results" | tr -d ' ')
		FOUND_COUNT=$((FOUND_COUNT + ORG_FOUND))
		rm "$temp_results"
	elif [ -f "$temp_results" ]; then
		rm "$temp_results"
	fi

	# Summary for this organization
	echo
	echo -e "${YELLOW}${BOLD}📊 Summary for ${ORG_NAME}:${RESET}"
	echo -e "   ${GREEN}${ORG_FOUND}${RESET} repositories with direct golang.org/x/crypto usage"
	echo -e "${BLUE}─────────────────────────────────────────────────────${RESET}"
	echo
done

# Scan individual repositories from xcrypto-repo-list.txt if it exists
REPO_LIST_FILE="xcrypto-repo-list.txt"
if [ -f "$REPO_LIST_FILE" ]; then
	echo -e "${YELLOW}${BOLD}👉 Individual Repositories from ${REPO_LIST_FILE}${RESET}"

	# Track results for individual repos
	INDIVIDUAL_FOUND=0
	INDIVIDUAL_COUNT=0

	# Use a separate file to store results
	temp_results=$(mktemp)

	while IFS= read -r repo_input || [ -n "$repo_input" ]; do
		# Skip empty lines and comments (# or //)
		[[ -z "$repo_input" || "$repo_input" =~ ^[[:space:]]*(#|//) ]] && continue

		# Normalize repo format: extract owner/repo from various formats
		repo=$(echo "$repo_input" | sed -e 's|https://github.com/||' -e 's|github.com/||' -e 's|^[[:space:]]*||' -e 's|[[:space:]]*$||')

		# Skip if still empty after normalization
		[[ -z "$repo" ]] && continue

		INDIVIDUAL_COUNT=$((INDIVIDUAL_COUNT + 1))

		# Get default branch and fork status for the repo
		echo -ne "   📂 ${repo}... "
		repo_info=$(gh repo view "$repo" --json defaultBranchRef,isFork 2>/dev/null)

		if [[ $? -ne 0 || -z "$repo_info" ]]; then
			echo -e "${RED}✗ Failed to fetch repo info${RESET}"
			continue
		fi

		branch=$(echo "$repo_info" | jq -r '.defaultBranchRef.name')
		is_fork=$(echo "$repo_info" | jq -r '.isFork')

		echo -ne "on branch ${branch}... "

		# Check if repo is a fork (either from cache or API)
		if is_in_cache "$repo" "$FORK_CACHE" || [ "$is_fork" = "true" ]; then
			echo -e "${BLUE}⏩ skipped (fork)${RESET}"
			SKIPPED_FORKS=$((SKIPPED_FORKS + 1))
			# Add to cache if detected via API but not in cache yet
			if [ "$is_fork" = "true" ] && ! is_in_cache "$repo" "$FORK_CACHE"; then
				echo "$repo" >>"$FORK_CACHE"
			fi
			continue
		fi

		# Check if repo is in abandoned cache
		if is_in_cache "$repo" "$ABANDONED_CACHE"; then
			echo -e "${BLUE}⏩ skipped (abandoned)${RESET}"
			SKIPPED_ABANDONED=$((SKIPPED_ABANDONED + 1))
			continue
		fi

		# Check if repo is abandoned (no commits in last 6 months)
		if is_repo_abandoned "$repo" "$branch"; then
			echo -e "${BLUE}⏩ skipped (abandoned - no recent commits)${RESET}"
			echo "$repo" >>"$ABANDONED_CACHE"
			SKIPPED_ABANDONED=$((SKIPPED_ABANDONED + 1))
			continue
		fi

		# Check if repo is in no-go.mod cache
		if is_in_cache "$repo" "$NOGOMOD_CACHE"; then
			echo -e "${BLUE}⏩ skipped (no go.mod)${RESET}"
			SKIPPED_NOGOMOD=$((SKIPPED_NOGOMOD + 1))
			continue
		fi

		# Fetch go.mod raw content from default branch
		raw_url="https://raw.githubusercontent.com/$repo/$branch/go.mod"
		go_mod=$(curl -s -f "$raw_url")

		if [[ $? -ne 0 ]]; then
			echo -e "${YELLOW}no go.mod (cached)${RESET}"
			echo "$repo" >>"$NOGOMOD_TEMP"
			SKIPPED_NOGOMOD=$((SKIPPED_NOGOMOD + 1))
			continue
		fi

		# Check for direct dependency (exclude // indirect)
		# Matches both: "require golang.org/x/crypto v..." and "	golang.org/x/crypto v..." (inside require block)
		if echo "$go_mod" | grep 'golang.org/x/crypto' | grep -vq '// indirect'; then
			# Extract the version being used
			xcrypto_version=$(extract_xcrypto_version "$go_mod")
			version_status="unknown"

			if [ "$LATEST_XCRYPTO_VERSION" != "unknown" ] && [ "$xcrypto_version" != "unknown" ]; then
				version_status=$(compare_versions "$xcrypto_version" "$LATEST_XCRYPTO_VERSION")
			fi

			# Show version status in terminal output
			if [ "$version_status" = "current" ]; then
				echo -e "${GREEN}✓ USES crypto directly (${xcrypto_version} ✅ current)${RESET}"
			elif [ "$version_status" = "outdated" ]; then
				echo -e "${GREEN}✓ USES crypto directly${RESET} ${YELLOW}(${xcrypto_version} ⚠️  outdated)${RESET}"
			else
				echo -e "${GREEN}✓ USES crypto directly (${xcrypto_version})${RESET}"
			fi

			echo "$repo" >>"$temp_results"
			XCRYPTO_REPOS+=("$repo")

			# Fetch last commit date from default branch for tracking issue
			last_commit=$(gh api "repos/${repo}/commits/${branch}" --jq '.commit.committer.date' 2>/dev/null || echo "unknown")

			# Check if repo has Dependabot configured
			dependabot_status=$(check_dependabot "$repo" "$branch")

			# Manage tracking issue in the repo (create/close based on version status)
			manage_repo_issue "$repo" "$xcrypto_version" "$LATEST_XCRYPTO_VERSION" "$version_status" "$dependabot_status"

			# Store for org-specific data: org|repo|branch|last_commit|dependabot_status|xcrypto_version|issue_url
			echo "Individual Repositories|$repo|$branch|$last_commit|$dependabot_status|$xcrypto_version|$LAST_REPO_ISSUE_URL" >>"$ORG_DATA_FILE"
		else
			echo -e "${RED}✗ NO direct usage${RESET}"
		fi
	done <"$REPO_LIST_FILE"

	# Count the results
	if [ -f "$temp_results" ] && [ -s "$temp_results" ]; then
		INDIVIDUAL_FOUND=$(wc -l <"$temp_results" | tr -d ' ')
		FOUND_COUNT=$((FOUND_COUNT + INDIVIDUAL_FOUND))
		TOTAL_REPOS=$((TOTAL_REPOS + INDIVIDUAL_COUNT))
		rm "$temp_results"
	elif [ -f "$temp_results" ]; then
		TOTAL_REPOS=$((TOTAL_REPOS + INDIVIDUAL_COUNT))
		rm "$temp_results"
	fi

	# Summary for individual repositories
	echo
	echo -e "${YELLOW}${BOLD}📊 Summary for Individual Repositories:${RESET}"
	echo -e "   ${GREEN}${INDIVIDUAL_FOUND}${RESET} repositories with direct golang.org/x/crypto usage (out of ${INDIVIDUAL_COUNT} scanned)"
	echo -e "${BLUE}─────────────────────────────────────────────────────${RESET}"
	echo
fi

# Update no-go.mod cache
if [ -f "$NOGOMOD_TEMP" ] && [ -s "$NOGOMOD_TEMP" ]; then
	cat "$NOGOMOD_TEMP" >>"$NOGOMOD_CACHE"
	sort -u "$NOGOMOD_CACHE" -o "$NOGOMOD_CACHE"
	NEW_NOGOMOD=$(wc -l <"$NOGOMOD_TEMP" | tr -d ' ')
	echo -e "${BLUE}💾 Updated no-go.mod cache with ${NEW_NOGOMOD} new entries${RESET}"
	echo
fi
rm -f "$NOGOMOD_TEMP"

# Sort and deduplicate fork cache
if [ -f "$FORK_CACHE" ] && [ -s "$FORK_CACHE" ]; then
	sort -u "$FORK_CACHE" -o "$FORK_CACHE"
fi

# Sort and deduplicate abandoned cache
if [ -f "$ABANDONED_CACHE" ] && [ -s "$ABANDONED_CACHE" ]; then
	sort -u "$ABANDONED_CACHE" -o "$ABANDONED_CACHE"
fi

# Final summary
echo -e "${BOLD}${BLUE}📈 FINAL RESULTS:${RESET}"
echo -e "${BOLD}   Total repositories scanned:${RESET} ${TOTAL_REPOS}"
echo -e "${BOLD}   Repositories skipped (forks):${RESET} ${BLUE}${SKIPPED_FORKS}${RESET}"
echo -e "${BOLD}   Repositories skipped (abandoned):${RESET} ${BLUE}${SKIPPED_ABANDONED}${RESET}"
echo -e "${BOLD}   Repositories skipped (no go.mod):${RESET} ${BLUE}${SKIPPED_NOGOMOD}${RESET}"
echo -e "${BOLD}   Repositories with direct crypto usage:${RESET} ${GREEN}${FOUND_COUNT}${RESET}"

# Calculate percentage safely (avoid division by zero)
ACTUAL_SCANNED=$((TOTAL_REPOS - SKIPPED_FORKS - SKIPPED_ABANDONED - SKIPPED_NOGOMOD))
if [ $ACTUAL_SCANNED -gt 0 ]; then
	PERCENTAGE=$(awk "BEGIN { printf \"%.1f%%\", ($FOUND_COUNT/$ACTUAL_SCANNED)*100 }")
else
	PERCENTAGE="N/A (no repositories scanned)"
fi
echo -e "${BOLD}   Usage percentage:${RESET} ${PERCENTAGE}"

# Show issue management summary if --create-issues was used
if [ "$CREATE_ISSUES" = "true" ]; then
	echo
	echo -e "${BOLD}${BLUE}📋 ISSUE MANAGEMENT:${RESET}"
	if [ $ISSUES_CREATED -gt 0 ]; then
		echo -e "${BOLD}   Issues created:${RESET} ${YELLOW}${ISSUES_CREATED}${RESET}"
	fi
	if [ $ISSUES_UPDATED -gt 0 ]; then
		echo -e "${BOLD}   Issues updated:${RESET} ${BLUE}${ISSUES_UPDATED}${RESET}"
	fi
	if [ $ISSUES_REOPENED -gt 0 ]; then
		echo -e "${BOLD}   Issues reopened:${RESET} ${YELLOW}${ISSUES_REOPENED}${RESET}"
	fi
	if [ $ISSUES_CLOSED -gt 0 ]; then
		echo -e "${BOLD}   Issues closed:${RESET} ${GREEN}${ISSUES_CLOSED}${RESET}"
	fi
	if [ $ISSUES_CREATED -eq 0 ] && [ $ISSUES_UPDATED -eq 0 ] && [ $ISSUES_REOPENED -eq 0 ] && [ $ISSUES_CLOSED -eq 0 ]; then
		echo -e "${BOLD}   No issue changes needed${RESET}"
	fi
fi
echo

# Display table of repositories using x/crypto directly
if [ ${#XCRYPTO_REPOS[@]} -gt 0 ]; then
	echo -e "${GREEN}${BOLD}📦 REPOSITORIES USING GOLANG.ORG/X/CRYPTO DIRECTLY:${RESET}"
	echo -e "${GREEN}═══════════════════════════════════════════════════════════════════════════════════════════${RESET}"
	echo
	if [ "$LATEST_XCRYPTO_VERSION" != "unknown" ]; then
		echo -e "${BLUE}📌 Latest golang.org/x/crypto version: ${BOLD}${LATEST_XCRYPTO_VERSION}${RESET}"
		echo
	fi
	printf "${BOLD}%-50s %-15s %-15s %-12s${RESET}\n" "Repository" "Version" "Status" "Dependabot"
	printf "%s\n" "────────────────────────────────────────────────────────────────────────────────────────────────"

	# Read from ORG_DATA_FILE to get version info
	while IFS='|' read -r org repo branch last_commit dependabot_status xcrypto_version; do
		# Determine version status
		if [ "$LATEST_XCRYPTO_VERSION" != "unknown" ] && [ "$xcrypto_version" != "unknown" ]; then
			version_status=$(compare_versions "$xcrypto_version" "$LATEST_XCRYPTO_VERSION")
			if [ "$version_status" = "current" ]; then
				status_display="${GREEN}✅ Current${RESET}"
			elif [ "$version_status" = "outdated" ]; then
				status_display="${YELLOW}⚠️  Outdated${RESET}"
			else
				status_display="—"
			fi
		else
			status_display="—"
		fi

		# Format dependabot status
		if [ "$dependabot_status" = "yes" ]; then
			dependabot_display="${GREEN}✅ Yes${RESET}"
		else
			dependabot_display="${RED}❌ No${RESET}"
		fi

		printf "%-50s %-15s %b %b\n" "$repo" "$xcrypto_version" "$status_display" "$dependabot_display"
	done <"$ORG_DATA_FILE"

	echo
	echo -e "${YELLOW}${BOLD}💡 NOTE:${RESET}"
	echo -e "${YELLOW}   These repositories directly depend on golang.org/x/crypto${RESET}"
	echo -e "${YELLOW}   This is informational - x/crypto is a valid and maintained package${RESET}"
	if [ "$LATEST_XCRYPTO_VERSION" != "unknown" ]; then
		echo -e "${YELLOW}   ⚠️  = version is behind latest (${LATEST_XCRYPTO_VERSION}), ✅ = up to date${RESET}"
	fi
	echo

	# Generate Markdown report
	echo "📝 Generating markdown report: $OUTPUT_MD"
	{
		echo "# golang.org/x/crypto Direct Usage Report"
		echo ""
		echo "**Generated:** $(date '+%Y-%m-%d %H:%M:%S %Z')"
		echo ""
		echo "## Summary"
		echo ""
		echo "- **Total repositories scanned:** ${TOTAL_REPOS}"
		echo "- **Repositories skipped (forks):** ${SKIPPED_FORKS}"
		echo "- **Repositories skipped (abandoned - no commits in 6 months):** ${SKIPPED_ABANDONED}"
		echo "- **Repositories skipped (no go.mod):** ${SKIPPED_NOGOMOD}"
		echo "- **Repositories actually checked:** ${ACTUAL_SCANNED}"
		echo "- **Repositories using x/crypto directly:** ${FOUND_COUNT}"
		echo "- **Usage percentage:** ${PERCENTAGE}"
		echo ""
		echo "## 📦 Important Note"
		echo ""
		echo "The \`golang.org/x/crypto\` package is a **valid and actively maintained** package from the Go project."
		echo ""
		echo "This report tracks direct dependencies for informational purposes, such as:"
		echo "- Understanding security-sensitive dependencies"
		echo "- Tracking cryptographic implementations across the organization"
		echo "- Ensuring proper review and maintenance of crypto-related code"
		echo ""
		echo "## Repositories Using golang.org/x/crypto Directly"
		echo ""
		if [ "$LATEST_XCRYPTO_VERSION" != "unknown" ]; then
			echo "**Latest golang.org/x/crypto version:** \`${LATEST_XCRYPTO_VERSION}\`"
			echo ""
		fi
		echo "| # | Repository | Version | Status | Dependabot |"
		echo "|---|------------|---------|--------|------------|"

		counter=1
		while IFS='|' read -r org repo branch last_commit dependabot_status xcrypto_version; do
			# Determine version status
			if [ "$LATEST_XCRYPTO_VERSION" != "unknown" ] && [ "$xcrypto_version" != "unknown" ]; then
				version_status=$(compare_versions "$xcrypto_version" "$LATEST_XCRYPTO_VERSION")
				if [ "$version_status" = "current" ]; then
					status_display="✅ Current"
				elif [ "$version_status" = "outdated" ]; then
					status_display="⚠️ Outdated"
				else
					status_display="—"
				fi
			else
				status_display="—"
			fi
			# Format dependabot status
			if [ "$dependabot_status" = "yes" ]; then
				dependabot_display="✅ Yes"
			else
				dependabot_display="❌ No"
			fi
			echo "| $counter | [\`$repo\`](https://github.com/$repo) | \`$xcrypto_version\` | $status_display | $dependabot_display |"
			counter=$((counter + 1))
		done <"$ORG_DATA_FILE"

		echo ""
		echo "---"
		echo ""
		echo "## About golang.org/x/crypto"
		echo ""
		echo "The \`golang.org/x/crypto\` package provides supplementary cryptographic primitives for Go programs."
		echo ""
		echo "### Key Information"
		echo ""
		echo "- **Status:** Actively maintained by the Go team"
		echo "- **Repository:** [golang.org/x/crypto](https://pkg.go.dev/golang.org/x/crypto)"
		echo "- **Purpose:** Provides cryptographic primitives not included in the standard library"
		echo ""
		echo "### Common Use Cases"
		echo ""
		echo "1. **SSH implementations:** \`golang.org/x/crypto/ssh\`"
		echo "2. **Additional encryption algorithms:** \`golang.org/x/crypto/nacl\`, \`golang.org/x/crypto/chacha20poly1305\`"
		echo "3. **Password hashing:** \`golang.org/x/crypto/bcrypt\`, \`golang.org/x/crypto/argon2\`"
		echo "4. **Cryptographic protocols:** \`golang.org/x/crypto/openpgp\`, \`golang.org/x/crypto/acme\`"
		echo ""
		echo "### Security Considerations"
		echo ""
		echo "When using \`golang.org/x/crypto\`:"
		echo ""
		echo "- Keep the dependency updated to get security fixes"
		echo "- Review security advisories for the package"
		echo "- Ensure proper usage of cryptographic primitives"
		echo "- Follow security best practices for key management"
		echo ""
	} >"$OUTPUT_MD"

	echo -e "${GREEN}✅ Markdown report saved to: $OUTPUT_MD${RESET}"
	echo
else
	echo -e "${YELLOW}${BOLD}ℹ️  No repositories found using golang.org/x/crypto directly${RESET}"
	echo

	# Generate empty report
	{
		echo "# golang.org/x/crypto Direct Usage Report"
		echo ""
		echo "**Generated:** $(date '+%Y-%m-%d %H:%M:%S %Z')"
		echo ""
		echo "## Summary"
		echo ""
		echo "- **Total repositories scanned:** ${TOTAL_REPOS}"
		echo "- **Repositories skipped (forks):** ${SKIPPED_FORKS}"
		echo "- **Repositories skipped (abandoned - no commits in 6 months):** ${SKIPPED_ABANDONED}"
		echo "- **Repositories skipped (no go.mod):** ${SKIPPED_NOGOMOD}"
		echo "- **Repositories actually checked:** ${ACTUAL_SCANNED}"
		echo "- **Repositories using x/crypto directly:** ${FOUND_COUNT}"
		echo ""
		echo "## ℹ️  Result"
		echo ""
		echo "No repositories found with direct dependencies on \`golang.org/x/crypto\`."
		echo ""
	} >"$OUTPUT_MD"

	echo "📝 Empty report saved to: $OUTPUT_MD"
	echo
fi

# Update tracking issue in telco-bot repo
echo -e "${BLUE}${BOLD}📋 Updating Central Tracking Issue${RESET}"
echo -e "${BLUE}─────────────────────────────────────────────────────${RESET}"
echo -e "${BLUE}   Building issue body with ${FOUND_COUNT} repositories using x/crypto directly...${RESET}"

# Build the issue body - include latest version if known
LATEST_VERSION_INFO=""
if [ "$LATEST_XCRYPTO_VERSION" != "unknown" ]; then
	LATEST_VERSION_INFO="**Latest Version:** \`${LATEST_XCRYPTO_VERSION}\` ([view tags](https://github.com/golang/crypto/tags))  "
fi

ISSUE_BODY="# golang.org/x/crypto Direct Usage Report

**Last Updated:** $(date -u '+%Y-%m-%d %H:%M:%S UTC')  
**Package:** [golang.org/x/crypto](https://pkg.go.dev/golang.org/x/crypto)  
${LATEST_VERSION_INFO}
**Status:** Actively maintained by the Go team

## Summary

- **Total Repositories Scanned:** ${TOTAL_REPOS}
- **Repositories Skipped (forks):** ${SKIPPED_FORKS}
- **Repositories Skipped (abandoned - no commits in 6 months):** ${SKIPPED_ABANDONED}
- **Repositories Skipped (no go.mod):** ${SKIPPED_NOGOMOD}
- **Repositories Actually Checked:** ${ACTUAL_SCANNED}
- **Repositories Using x/crypto Directly:** ${FOUND_COUNT}
- **Usage Percentage:** ${PERCENTAGE}

### Status Legend

| Symbol | Meaning |
|--------|---------|
| ✅ Current | Using the latest version of x/crypto |
| ⚠️ Outdated | Using an older version, consider updating |
| ✅ Yes (Dependabot) | Repository has Dependabot configured |
| ❌ No (Dependabot) | Repository does not have Dependabot configured |

---

"

if [ $FOUND_COUNT -gt 0 ]; then
	# Group by organization and create tables
	for ORG_NAME in "${ORGS[@]}" "Individual Repositories"; do
		# Check if this org has any repos using x/crypto directly
		ORG_REPOS=$(grep "^${ORG_NAME}|" "$ORG_DATA_FILE" 2>/dev/null || true)

		if [ -n "$ORG_REPOS" ]; then
			ORG_COUNT=$(echo "$ORG_REPOS" | wc -l | tr -d ' ')

			# Create clickable org header (skip for "Individual Repositories")
			if [ "$ORG_NAME" = "Individual Repositories" ]; then
				ISSUE_BODY+="## ${ORG_NAME}

"
			else
				ISSUE_BODY+="## [${ORG_NAME}](https://github.com/${ORG_NAME})

"
			fi

			ISSUE_BODY+="**Repositories Using x/crypto Directly:** ${ORG_COUNT}

| Repository | x/crypto Version | Status | Dependabot | Last Updated | Tracking Issue |
|------------|------------------|--------|------------|--------------|----------------|
"

			# Sort by last commit date (most recent first) and add each repo to the table
			echo "$ORG_REPOS" | sort -t'|' -k4 -r | while IFS='|' read -r org repo branch last_commit dependabot_status xcrypto_version issue_url; do
				# Extract just the repo name (without org prefix)
				repo_name="${repo##*/}"
				# Escape pipe characters in repo names if any
				repo_display=$(echo "$repo_name" | sed 's/|/\\|/g')
				# Format the date nicely (from ISO8601 to readable format)
				if [ "$last_commit" != "unknown" ]; then
					# Try macOS date format first, then Linux, then fall back to raw
					last_commit_display=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_commit" "+%Y-%m-%d" 2>/dev/null || date -d "$last_commit" "+%Y-%m-%d" 2>/dev/null || echo "${last_commit:0:10}")
				else
					last_commit_display="Unknown"
				fi

				# Format dependabot status
				if [ "$dependabot_status" = "yes" ]; then
					dependabot_display="✅ Yes"
				else
					dependabot_display="❌ No"
				fi

				# Determine version status for display
				if [ "$LATEST_XCRYPTO_VERSION" != "unknown" ] && [ "$xcrypto_version" != "unknown" ]; then
					version_status=$(compare_versions "$xcrypto_version" "$LATEST_XCRYPTO_VERSION")
					if [ "$version_status" = "current" ]; then
						version_status_display="✅ Current"
					elif [ "$version_status" = "outdated" ]; then
						version_status_display="⚠️ Outdated"
					else
						version_status_display="—"
					fi
				else
					version_status_display="—"
				fi

				# Format tracking issue link
				if [ -n "$issue_url" ]; then
					# Extract issue number from URL
					issue_num=$(echo "$issue_url" | grep -oE '[0-9]+$')
					tracking_issue_display="[#${issue_num}](${issue_url})"
				else
					tracking_issue_display="—"
				fi

				echo "| [\`${repo_display}\`](https://github.com/${repo}) | \`${xcrypto_version}\` | ${version_status_display} | ${dependabot_display} | ${last_commit_display} | ${tracking_issue_display} |"
			done >>"${ORG_DATA_FILE}.table"

			ISSUE_BODY+="$(cat "${ORG_DATA_FILE}.table")

"
			rm -f "${ORG_DATA_FILE}.table"
		fi
	done

	ISSUE_BODY+="---

## About golang.org/x/crypto

The \`golang.org/x/crypto\` package provides supplementary cryptographic primitives for Go programs.

### Key Information

- **Status:** Actively maintained by the Go team
- **Repository:** [golang.org/x/crypto](https://pkg.go.dev/golang.org/x/crypto)
- **Purpose:** Provides cryptographic primitives not included in the standard library

### Common Use Cases

- **SSH implementations:** \`golang.org/x/crypto/ssh\`
- **Additional encryption algorithms:** \`golang.org/x/crypto/chacha20poly1305\`
- **Password hashing:** \`golang.org/x/crypto/bcrypt\`, \`golang.org/x/crypto/argon2\`
- **Cryptographic protocols:** \`golang.org/x/crypto/acme\`

### Why Track This?

This tracking issue helps us:

1. **Understand security-sensitive dependencies** across our codebase
2. **Track cryptographic implementations** for security reviews
3. **Ensure proper maintenance** of crypto-related dependencies
4. **Monitor for security advisories** affecting x/crypto

### Security Considerations

When using \`golang.org/x/crypto\`:

- Keep the dependency updated to get security fixes
- Review security advisories for the package
- Ensure proper usage of cryptographic primitives
- Follow security best practices for key management

### Resources

- [golang.org/x/crypto Documentation](https://pkg.go.dev/golang.org/x/crypto)
- [Go Security Policy](https://go.dev/security)
- [Go Vulnerability Database](https://vuln.go.dev/)

"
else
	ISSUE_BODY+="## ✅ All Clear!

No repositories currently have direct dependencies on \`golang.org/x/crypto\`.

"
fi

ISSUE_BODY+="---

*This issue is automatically updated by the [xcrypto-lookup.sh](https://github.com/${TRACKING_REPO}/blob/main/scripts/xcrypto-lookup.sh) script.*"

# Check if tracking issue exists
echo -e "${BLUE}   Issue body built successfully${RESET}"
echo -ne "   Checking for existing tracking issue... "
EXISTING_ISSUE=$(gh issue list --repo "$TRACKING_REPO" --search "in:title \"${TRACKING_ISSUE_TITLE}\"" --state all --json number,title,state --jq ".[] | select(.title == \"${TRACKING_ISSUE_TITLE}\") | .number" | head -1)

if [ -n "$EXISTING_ISSUE" ]; then
	echo -e "${GREEN}found (#${EXISTING_ISSUE})${RESET}"
	echo -ne "   Updating issue #${EXISTING_ISSUE}... "

	# Check if issue is closed and reopen it if there are repos using x/crypto directly
	ISSUE_STATE=$(gh issue view "$EXISTING_ISSUE" --repo "$TRACKING_REPO" --json state --jq '.state')
	if [ "$ISSUE_STATE" = "CLOSED" ] && [ $FOUND_COUNT -gt 0 ]; then
		gh issue reopen "$EXISTING_ISSUE" --repo "$TRACKING_REPO" &>/dev/null
	fi

	if gh issue edit "$EXISTING_ISSUE" --repo "$TRACKING_REPO" --body "$ISSUE_BODY" &>/dev/null; then
		echo -e "${GREEN}✓ Updated${RESET}"
		echo -e "   ${BLUE}View at: https://github.com/${TRACKING_REPO}/issues/${EXISTING_ISSUE}${RESET}"
	else
		echo -e "${RED}✗ Failed to update${RESET}"
	fi
else
	echo -e "${YELLOW}not found${RESET}"
	echo -ne "   Creating new tracking issue... "

	NEW_ISSUE=$(gh issue create --repo "$TRACKING_REPO" --title "$TRACKING_ISSUE_TITLE" --body "$ISSUE_BODY" 2>/dev/null)
	if [ $? -eq 0 ]; then
		ISSUE_NUMBER=$(echo "$NEW_ISSUE" | grep -oE '[0-9]+$')
		echo -e "${GREEN}✓ Created (#${ISSUE_NUMBER})${RESET}"
		echo -e "   ${BLUE}View at: ${NEW_ISSUE}${RESET}"
	else
		echo -e "${RED}✗ Failed to create${RESET}"
	fi
fi

echo

# Count outdated repos from the ORG_DATA_FILE before cleanup
OUTDATED_COUNT=0
if [ -f "$ORG_DATA_FILE" ]; then
	while IFS='|' read -r org repo branch last_commit dependabot_status xcrypto_version; do
		if [ "$LATEST_XCRYPTO_VERSION" != "unknown" ] && [ "$xcrypto_version" != "unknown" ]; then
			version_status=$(compare_versions "$xcrypto_version" "$LATEST_XCRYPTO_VERSION")
			if [ "$version_status" = "outdated" ]; then
				OUTDATED_COUNT=$((OUTDATED_COUNT + 1))
			fi
		fi
	done <"$ORG_DATA_FILE"
fi

# Get the tracking issue number (either existing or newly created)
TRACKING_ISSUE_NUMBER="${EXISTING_ISSUE:-$ISSUE_NUMBER}"
TRACKING_ISSUE_URL="https://github.com/${TRACKING_REPO}/issues/${TRACKING_ISSUE_NUMBER}"

# Send Slack notification if XCRYPTO_SLACK_WEBHOOK is set
# This calls the separate xcrypto-slack.sh script which handles the notification
if [ -n "$XCRYPTO_SLACK_WEBHOOK" ]; then
	"$SCRIPT_DIR/xcrypto-slack.sh" "$TOTAL_REPOS" "${#ORGS[@]}" "$OUTDATED_COUNT" "$FOUND_COUNT" "$TRACKING_ISSUE_URL"
fi

# Cleanup temporary files
rm -f "$ORG_DATA_FILE"

echo -e "${GREEN}${BOLD}✅ Scan completed successfully!${RESET}"
