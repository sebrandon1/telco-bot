#!/bin/bash

#===============================================================================
# GOLANGCI-LINT VERSION CHECKER
#===============================================================================
#
# DESCRIPTION:
#   This script scans GitHub organizations for Go repositories and checks
#   whether they are using outdated versions of golangci-lint. It examines
#   GitHub Actions workflows, Makefiles, and other configuration files to
#   identify the golangci-lint version in use.
#
#   GolangCI-lint is a fast Go linters aggregator that helps maintain code
#   quality. Keeping it up to date ensures you have the latest linters and
#   bug fixes.
#
# PREREQUISITES:
#   1. GitHub CLI (gh) must be installed on your system
#      - Install: https://cli.github.com/
#      - macOS: brew install gh
#      - Linux: See https://github.com/cli/cli/blob/trunk/docs/install_linux.md
#   2. GitHub CLI must be authenticated with sufficient permissions
#      - Run: gh auth login
#      - Requires read access to repositories in target organizations
#   3. curl and jq must be available (typically pre-installed on most systems)
#   4. Internet connection to fetch repository data and configuration files
#
# USAGE:
#   ./golangci-lint-checker.sh [OPTIONS]
#
# OPTIONS:
#   --create-issues    Create GitHub issues on each outdated repository
#   --no-tracking      Skip updating the central tracking issue in telco-bot repo
#   --clear-cache      Clear all caches and rescan everything
#   --help             Show this help message
#
# TRACKING ISSUE:
#   By default, the script maintains a central tracking issue in the telco-bot repo
#   (https://github.com/redhat-best-practices-for-k8s/telco-bot/issues)
#   titled "Tracking Outdated GolangCI-Lint Versions". This issue is automatically
#   created if it doesn't exist and updated with each run to show current status.
#
# CONFIGURATION:
#   You can customize which organizations to scan by editing the ORGS array
#   below (line ~127). Add or remove organization names as needed:
#
#   ORGS=("your-org" "another-org" "third-org")
#
#   You can also specify individual repositories in golangci-lint-repo-list.txt
#   (one per line). Supported formats:
#     - owner/repo
#     - github.com/owner/repo
#     - https://github.com/owner/repo
#
#   To exclude specific repositories from scanning, add them to
#   golangci-lint-repo-blocklist.txt using the same format.
#
# OUTPUT:
#   The script provides:
#   - Real-time progress as it scans each repository
#   - Per-organization summary of findings
#   - Final detailed report of outdated repositories
#   - Color-coded output for easy reading
#   - Optional GitHub issue creation for outdated repos
#   - Markdown report file (golangci-lint-report.md)
#
# LIMITATIONS:
#   - Limited to 1000 repositories per organization (configurable via LIMIT)
#   - May not detect all instances of golangci-lint usage (e.g., custom scripts)
#   - Requires public access to configuration files or appropriate permissions
#
# REFERENCE:
#   - GolangCI-lint repository: https://github.com/golangci/golangci-lint
#   - GolangCI-lint releases: https://github.com/golangci/golangci-lint/releases
#===============================================================================

# Check for help flag first (before any other checks)
for arg in "$@"; do
	if [ "$arg" = "--help" ] || [ "$arg" = "-h" ]; then
		awk '/^#=====/ { if (++count == 3) exit; next } count == 2 && /^#/ { sub(/^# ?/, ""); print }' "$0"
		exit 0
	fi
done

# Check if GitHub CLI is installed
echo "🔧 Checking GitHub CLI installation..."
if ! command -v gh &>/dev/null; then
	echo -e "\033[0;31m❌ ERROR: GitHub CLI (gh) is not installed!\033[0m"
	echo -e "\033[0;33m💡 Please install it first:\033[0m"
	echo -e "\033[0;33m   macOS: brew install gh\033[0m"
	echo -e "\033[0;33m   Linux: https://github.com/cli/cli/blob/trunk/docs/install_linux.md\033[0m"
	echo -e "\033[0;33m   Or visit: https://cli.github.com/\033[0m"
	exit 1
fi
echo -e "\033[0;32m✅ GitHub CLI is installed\033[0m"

# Check if GitHub CLI is logged in
echo "🔒 Checking GitHub CLI authentication..."
if ! gh auth status &>/dev/null; then
	echo -e "\033[0;31m❌ ERROR: GitHub CLI is not logged in!\033[0m"
	echo -e "\033[0;33m💡 Please run 'gh auth login' to authenticate first.\033[0m"
	exit 1
fi
echo -e "\033[0;32m✅ GitHub CLI authenticated successfully\033[0m"

# Check if jq is installed
echo "🔧 Checking jq installation..."
if ! command -v jq &>/dev/null; then
	echo -e "\033[0;31m❌ ERROR: jq is not installed!\033[0m"
	echo -e "\033[0;33m💡 Please install it first:\033[0m"
	echo -e "\033[0;33m   macOS: brew install jq\033[0m"
	echo -e "\033[0;33m   Linux: sudo apt-get install jq (Debian/Ubuntu)\033[0m"
	echo -e "\033[0;33m   Or visit: https://stedolan.github.io/jq/\033[0m"
	exit 1
fi
echo -e "\033[0;32m✅ jq is installed\033[0m"
echo

# Parse command line arguments
CREATE_ISSUES=false
UPDATE_TRACKING=true
CLEAR_CACHE=false
for arg in "$@"; do
	case $arg in
	--create-issues)
		CREATE_ISSUES=true
		shift
		;;
	--no-tracking)
		UPDATE_TRACKING=false
		shift
		;;
	--clear-cache)
		CLEAR_CACHE=true
		shift
		;;
	*)
		echo -e "\033[0;31m❌ ERROR: Unknown option: $arg\033[0m"
		echo "Use --help or -h for usage information"
		exit 1
		;;
	esac
done

# List of orgs to scan
ORGS=("redhat-best-practices-for-k8s" "openshift-kni" "redhat-openshift-ecosystem" "redhatci" "openshift")

LIMIT=1000
OUTDATED_COUNT=0
TOTAL_GO_REPOS=0
TOTAL_REPOS=0
SKIPPED_FORKS=0
SKIPPED_NOGOMOD=0
SKIPPED_ABANDONED=0

# Terminal colors
GREEN="\033[0;32m"
RED="\033[0;31m"
BLUE="\033[0;34m"
YELLOW="\033[0;33m"
BOLD="\033[1m"
RESET="\033[0m"

# Tracking issue configuration
TRACKING_REPO="redhat-best-practices-for-k8s/telco-bot"
TRACKING_ISSUE_TITLE="Tracking Outdated GolangCI-Lint Versions"

# Get script directory for relative paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Shared cache files (used by all lookup scripts)
CACHE_DIR="$SCRIPT_DIR/caches"
CACHE_FILE="$CACHE_DIR/no-gomod.txt"
FORK_CACHE_FILE="$CACHE_DIR/forks.txt"
ABANDONED_CACHE_FILE="$CACHE_DIR/abandoned.txt"
OUTPUT_MD="golangci-lint-report.md"

# Ensure cache directory exists
mkdir -p "$CACHE_DIR"

# Inactivity threshold (in days)
INACTIVITY_DAYS=180 # 6 months

# Clear cache if requested
if [ "$CLEAR_CACHE" = true ]; then
	echo -e "${YELLOW}🗑️  Clearing caches...${RESET}"
	rm -f "$CACHE_FILE" "$FORK_CACHE_FILE" "$ABANDONED_CACHE_FILE"
	echo -e "${GREEN}✅ Caches cleared${RESET}"
	echo
fi

# Create empty cache files if they don't exist
touch "$CACHE_FILE" "$FORK_CACHE_FILE" "$ABANDONED_CACHE_FILE"

# Load cache of non-Go repos
NON_GO_REPOS=""
if [ -f "$CACHE_FILE" ] && [ -s "$CACHE_FILE" ]; then
	NON_GO_REPOS=$(cat "$CACHE_FILE")
	CACHE_SIZE=$(echo "$NON_GO_REPOS" | wc -l | tr -d ' ')
	echo -e "${BLUE}📦 Loaded non-Go repo cache: ${CACHE_SIZE} repositories${RESET}"
fi

# Load cache of fork repos
FORK_REPOS=""
if [ -f "$FORK_CACHE_FILE" ] && [ -s "$FORK_CACHE_FILE" ]; then
	FORK_REPOS=$(cat "$FORK_CACHE_FILE")
	FORK_CACHE_SIZE=$(echo "$FORK_REPOS" | wc -l | tr -d ' ')
	echo -e "${BLUE}🍴 Loaded fork cache: ${FORK_CACHE_SIZE} repositories${RESET}"
fi

# Load cache of abandoned repos
ABANDONED_REPOS=""
if [ -f "$ABANDONED_CACHE_FILE" ] && [ -s "$ABANDONED_CACHE_FILE" ]; then
	ABANDONED_REPOS=$(cat "$ABANDONED_CACHE_FILE")
	ABANDONED_CACHE_SIZE=$(echo "$ABANDONED_REPOS" | wc -l | tr -d ' ')
	echo -e "${BLUE}📋 Loaded abandoned repo cache: ${ABANDONED_CACHE_SIZE} repositories${RESET}"
fi

# Load blocklist of repos to exclude
BLOCKLIST_FILE="scripts/golangci-lint-repo-blocklist.txt"
BLOCKLIST=""
if [ -f "$BLOCKLIST_FILE" ]; then
	# Read and normalize blocklist entries
	while IFS= read -r repo_input || [ -n "$repo_input" ]; do
		# Skip empty lines and comments
		[[ -z "$repo_input" || "$repo_input" =~ ^[[:space:]]*(#|//) ]] && continue
		# Normalize repo format
		repo=$(echo "$repo_input" | sed -e 's|https://github.com/||' -e 's|github.com/||' -e 's|^[[:space:]]*||' -e 's|[[:space:]]*$||')
		[[ -z "$repo" ]] && continue
		BLOCKLIST="${BLOCKLIST}${repo}"$'\n'
	done <"$BLOCKLIST_FILE"
	BLOCKLIST_SIZE=$(echo "$BLOCKLIST" | grep -c '^' 2>/dev/null || echo "0")
	if [ "$BLOCKLIST_SIZE" -gt 0 ]; then
		echo -e "${YELLOW}🚫 Loaded blocklist: ${BLOCKLIST_SIZE} repositories will be excluded${RESET}"
	fi
fi

# Calculate cutoff date (6 months ago)
CUTOFF_DATE=$(date -u -v-${INACTIVITY_DAYS}d "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "${INACTIVITY_DAYS} days ago" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")

if [ -z "$CUTOFF_DATE" ]; then
	echo -e "${RED}❌ ERROR: Unable to calculate cutoff date${RESET}" >&2
	exit 1
fi

# Temporary files to store results
OUTDATED_REPOS_FILE=$(mktemp)
ORG_DATA_FILE=$(mktemp)
CACHE_UPDATES=$(mktemp)
FORK_CACHE_UPDATES=$(mktemp)
ABANDONED_CACHE_UPDATES=$(mktemp)

# Fetch latest golangci-lint version
echo -e "${BLUE}${BOLD}📡 Fetching latest golangci-lint version from GitHub${RESET}"
echo -e "${BLUE}─────────────────────────────────────────────────────${RESET}"

LATEST_VERSION=$(gh api repos/golangci/golangci-lint/releases/latest --jq '.tag_name' 2>/dev/null | sed 's/^v//')
if [[ $? -ne 0 || -z "$LATEST_VERSION" ]]; then
	echo -e "${RED}❌ ERROR: Failed to fetch latest golangci-lint version${RESET}"
	exit 1
fi

echo -e "${GREEN}✅ Latest golangci-lint version: v${LATEST_VERSION}${RESET}"
echo

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

# Function to compare two versions (returns 0 if v1 < v2, 1 if v1 >= v2)
# Versions should be in format like "1.55.2" (without 'v' prefix)
version_lt() {
	local v1=$1
	local v2=$2
	# Remove 'v' prefix if present
	v1=$(echo "$v1" | sed 's/^v//')
	v2=$(echo "$v2" | sed 's/^v//')
	# Compare using sort -V (version sort)
	if [ "$(printf '%s\n' "$v1" "$v2" | sort -V | head -1)" = "$v1" ] && [ "$v1" != "$v2" ]; then
		return 0
	else
		return 1
	fi
}

# Function to extract golangci-lint version from various sources
# Returns version string without 'v' prefix, or empty string if not found
extract_golangci_lint_version() {
	local repo="$1"
	local branch="$2"
	local version=""

	# Check GitHub Actions workflows first (most common location)
	local workflows=$(gh api "repos/${repo}/contents/.github/workflows" --jq '.[].name' 2>/dev/null)
	if [ -n "$workflows" ]; then
		for workflow in $workflows; do
			# Skip if not a YAML file
			[[ ! "$workflow" =~ \.(yml|yaml)$ ]] && continue

			local workflow_content=$(curl -s "https://raw.githubusercontent.com/${repo}/${branch}/.github/workflows/${workflow}")
			if [ -n "$workflow_content" ]; then
				# Look for golangci-lint-action version
				# Pattern: uses: golangci/golangci-lint-action@vX.Y.Z
				local action_version=$(echo "$workflow_content" | grep -oE 'golangci/golangci-lint-action@v[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 | sed 's/.*@v//')
				if [ -n "$action_version" ]; then
					version="$action_version"
					echo "$version|.github/workflows/${workflow}|action"
					return 0
				fi

				# Look for direct golangci-lint version specification
				# Pattern: version: vX.Y.Z or version: latest
				local direct_version=$(echo "$workflow_content" | grep -A 3 'golangci-lint-action' | grep -oE 'version:.*v[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 | sed 's/.*v//')
				if [ -n "$direct_version" ]; then
					version="$direct_version"
					echo "$version|.github/workflows/${workflow}|workflow"
					return 0
				fi
			fi
		done
	fi

	# Check Makefile
	local makefile_content=$(curl -s "https://raw.githubusercontent.com/${repo}/${branch}/Makefile")
	if [ -n "$makefile_content" ]; then
		# Look for golangci-lint version in various Makefile patterns
		# Pattern: GOLANGCI_LINT_VERSION = vX.Y.Z or similar
		local makefile_version=$(echo "$makefile_content" | grep -oE 'GOLANGCI[_-]?LINT[_-]?VERSION.*[=:].*v?[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 | grep -oE 'v?[0-9]+\.[0-9]+(\.[0-9]+)?' | sed 's/^v//')
		if [ -n "$makefile_version" ]; then
			version="$makefile_version"
			echo "$version|Makefile|makefile"
			return 0
		fi

		# Pattern: go install github.com/golangci/golangci-lint/cmd/golangci-lint@vX.Y.Z
		local install_version=$(echo "$makefile_content" | grep -oE 'golangci-lint/cmd/golangci-lint@v[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 | sed 's/.*@v//')
		if [ -n "$install_version" ]; then
			version="$install_version"
			echo "$version|Makefile|install"
			return 0
		fi
	fi

	# Check .golangci.yml or .golangci.yaml
	for config_file in ".golangci.yml" ".golangci.yaml"; do
		local config_content=$(curl -s "https://raw.githubusercontent.com/${repo}/${branch}/${config_file}")
		if [ -n "$config_content" ]; then
			# Look for version specification in config (less common, but possible)
			local config_version=$(echo "$config_content" | grep -oE 'version:.*v?[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 | grep -oE 'v?[0-9]+\.[0-9]+(\.[0-9]+)?' | sed 's/^v//')
			if [ -n "$config_version" ]; then
				version="$config_version"
				echo "$version|${config_file}|config"
				return 0
			fi
		fi
	done

	# No version found
	return 1
}

echo -e "${BLUE}${BOLD}🔍 SCANNING REPOSITORIES FOR OUTDATED GOLANGCI-LINT VERSIONS${RESET}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${RESET}"
echo -e "${BLUE}📅 Skipping repos with no commits since: ${CUTOFF_DATE:0:10}${RESET}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${RESET}"
echo

for ORG_NAME in "${ORGS[@]}"; do
	echo -e "${YELLOW}${BOLD}👉 Organization: ${ORG_NAME}${RESET}"

	# Get all repos first (including fork status)
	echo -e "${BLUE}   Fetching repository list...${RESET}"
	REPOS=$(gh repo list "$ORG_NAME" --limit "$LIMIT" --json nameWithOwner,defaultBranchRef,isArchived,isFork -q '.[] | select(.isArchived == false) | .nameWithOwner + " " + .defaultBranchRef.name + " " + (.isFork | tostring)')
	REPO_COUNT=$(echo "$REPOS" | wc -l | tr -d ' ')
	TOTAL_REPOS=$((TOTAL_REPOS + REPO_COUNT))

	echo -e "${BLUE}   Found ${REPO_COUNT} active repositories to scan${RESET}"
	echo

	# Track results for this organization
	ORG_OUTDATED=0
	ORG_GO_REPOS=0

	while read -r repo branch is_fork; do
		# Skip empty lines
		[[ -z "$repo" ]] && continue

		# Show a simple progress indicator
		echo -ne "   📂 ${repo} on branch ${branch}... "

		# Check fork cache first
		if is_in_cache "$repo" "$FORK_CACHE_FILE"; then
			echo -e "${BLUE}⏩ skipped (fork - cached)${RESET}"
			SKIPPED_FORKS=$((SKIPPED_FORKS + 1))
			continue
		fi

		# Skip forks detected from API
		if [ "$is_fork" = "true" ]; then
			echo -e "${BLUE}⏩ skipped (fork)${RESET}"
			echo "$repo" >>"$FORK_CACHE_UPDATES"
			SKIPPED_FORKS=$((SKIPPED_FORKS + 1))
			continue
		fi

		# Check blocklist
		if [ -n "$BLOCKLIST" ] && echo "$BLOCKLIST" | grep -q "^${repo}$"; then
			echo -e "${YELLOW}⏩ skipped (blocklisted)${RESET}"
			continue
		fi

		# Check abandoned cache
		if is_in_cache "$repo" "$ABANDONED_CACHE_FILE"; then
			echo -e "${BLUE}⏩ skipped (abandoned - cached)${RESET}"
			SKIPPED_ABANDONED=$((SKIPPED_ABANDONED + 1))
			continue
		fi

		# Check if repo is abandoned
		if is_repo_abandoned "$repo" "$branch"; then
			echo -e "${BLUE}⏩ skipped (abandoned - no recent commits)${RESET}"
			echo "$repo" >>"$ABANDONED_CACHE_UPDATES"
			SKIPPED_ABANDONED=$((SKIPPED_ABANDONED + 1))
			continue
		fi

		# Check non-Go cache
		if is_in_cache "$repo" "$CACHE_FILE"; then
			echo -e "${YELLOW}⏩ no go.mod (cached)${RESET}"
			SKIPPED_NOGOMOD=$((SKIPPED_NOGOMOD + 1))
			continue
		fi

		# Check if repo has go.mod (is a Go project)
		raw_url="https://raw.githubusercontent.com/$repo/$branch/go.mod"
		go_mod=$(curl -s -f "$raw_url")

		if [[ $? -ne 0 ]]; then
			echo -e "${YELLOW}no go.mod${RESET}"
			echo "$repo" >>"$CACHE_UPDATES"
			SKIPPED_NOGOMOD=$((SKIPPED_NOGOMOD + 1))
			continue
		fi

		ORG_GO_REPOS=$((ORG_GO_REPOS + 1))
		TOTAL_GO_REPOS=$((TOTAL_GO_REPOS + 1))

		# Extract golangci-lint version
		version_info=$(extract_golangci_lint_version "$repo" "$branch")

		if [[ -z "$version_info" ]]; then
			echo -e "${YELLOW}✓ No golangci-lint detected${RESET}"
			continue
		fi

		# Parse version info
		current_version=$(echo "$version_info" | cut -d'|' -f1)
		source_file=$(echo "$version_info" | cut -d'|' -f2)
		source_type=$(echo "$version_info" | cut -d'|' -f3)

		# Compare versions
		if version_lt "$current_version" "$LATEST_VERSION"; then
			echo -e "${RED}✗ OUTDATED (v${current_version} in ${source_file})${RESET}"
			ORG_OUTDATED=$((ORG_OUTDATED + 1))
			OUTDATED_COUNT=$((OUTDATED_COUNT + 1))

			# Fetch last commit date from default branch
			last_commit=$(gh api "repos/${repo}/commits/${branch}" --jq '.commit.committer.date' 2>/dev/null || echo "unknown")

			# Store for report
			# Format: org|repo|current_version|latest_version|source_file|source_type|branch|last_commit
			echo "$ORG_NAME|$repo|$current_version|$LATEST_VERSION|$source_file|$source_type|$branch|$last_commit" >>"$ORG_DATA_FILE"
			echo "$repo|$current_version|$source_file|$branch" >>"$OUTDATED_REPOS_FILE"
		else
			echo -e "${GREEN}✓ Up-to-date (v${current_version})${RESET}"
		fi
	done <<<"$REPOS"

	# Summary for this organization
	echo
	echo -e "${YELLOW}${BOLD}📊 Summary for ${ORG_NAME}:${RESET}"
	echo -e "   ${BLUE}Go repositories found:${RESET} ${ORG_GO_REPOS}"
	echo -e "   ${RED}Repositories with outdated golangci-lint:${RESET} ${ORG_OUTDATED}"
	if [ $ORG_GO_REPOS -gt 0 ]; then
		PERCENTAGE=$(awk "BEGIN { printf \"%.1f%%\", ($ORG_OUTDATED/$ORG_GO_REPOS)*100 }")
		echo -e "   ${BOLD}Outdated percentage:${RESET} ${PERCENTAGE}"
	fi
	echo -e "${BLUE}─────────────────────────────────────────────────────${RESET}"
	echo
done

# Scan individual repositories from golangci-lint-repo-list.txt if it exists
REPO_LIST_FILE="scripts/golangci-lint-repo-list.txt"
if [ -f "$REPO_LIST_FILE" ]; then
	echo -e "${YELLOW}${BOLD}👉 Individual Repositories from ${REPO_LIST_FILE}${RESET}"

	# Track results for individual repos
	INDIVIDUAL_OUTDATED=0
	INDIVIDUAL_GO_REPOS=0

	while IFS= read -r repo_input || [ -n "$repo_input" ]; do
		# Skip empty lines and comments
		[[ -z "$repo_input" || "$repo_input" =~ ^[[:space:]]*(#|//) ]] && continue

		# Normalize repo format
		repo=$(echo "$repo_input" | sed -e 's|https://github.com/||' -e 's|github.com/||' -e 's|^[[:space:]]*||' -e 's|[[:space:]]*$||')
		[[ -z "$repo" ]] && continue

		echo -ne "   📂 ${repo}... "

		# Check fork cache
		if is_in_cache "$repo" "$FORK_CACHE_FILE"; then
			echo -e "${BLUE}⏩ skipped (fork - cached)${RESET}"
			SKIPPED_FORKS=$((SKIPPED_FORKS + 1))
			continue
		fi

		# Check non-Go cache
		if is_in_cache "$repo" "$CACHE_FILE"; then
			echo -e "${YELLOW}⏩ no go.mod (cached)${RESET}"
			SKIPPED_NOGOMOD=$((SKIPPED_NOGOMOD + 1))
			continue
		fi

		# Get repo info
		repo_info=$(gh repo view "$repo" --json defaultBranchRef,isFork 2>/dev/null)
		if [[ $? -ne 0 || -z "$repo_info" ]]; then
			echo -e "${RED}✗ Failed to fetch repo info${RESET}"
			continue
		fi

		branch=$(echo "$repo_info" | jq -r '.defaultBranchRef.name')
		is_fork=$(echo "$repo_info" | jq -r '.isFork')

		# Skip forks
		if [ "$is_fork" = "true" ]; then
			echo -e "${BLUE}⏩ skipped (fork)${RESET}"
			echo "$repo" >>"$FORK_CACHE_UPDATES"
			SKIPPED_FORKS=$((SKIPPED_FORKS + 1))
			continue
		fi

		# Check blocklist
		if [ -n "$BLOCKLIST" ] && echo "$BLOCKLIST" | grep -q "^${repo}$"; then
			echo -e "${YELLOW}⏩ skipped (blocklisted)${RESET}"
			continue
		fi

		echo -ne "on branch ${branch}... "

		# Check if repo has go.mod
		raw_url="https://raw.githubusercontent.com/$repo/$branch/go.mod"
		go_mod=$(curl -s -f "$raw_url")

		if [[ $? -ne 0 ]]; then
			echo -e "${YELLOW}no go.mod${RESET}"
			echo "$repo" >>"$CACHE_UPDATES"
			SKIPPED_NOGOMOD=$((SKIPPED_NOGOMOD + 1))
			continue
		fi

		INDIVIDUAL_GO_REPOS=$((INDIVIDUAL_GO_REPOS + 1))
		TOTAL_GO_REPOS=$((TOTAL_GO_REPOS + 1))

		# Extract golangci-lint version
		version_info=$(extract_golangci_lint_version "$repo" "$branch")

		if [[ -z "$version_info" ]]; then
			echo -e "${YELLOW}✓ No golangci-lint detected${RESET}"
			continue
		fi

		# Parse version info
		current_version=$(echo "$version_info" | cut -d'|' -f1)
		source_file=$(echo "$version_info" | cut -d'|' -f2)
		source_type=$(echo "$version_info" | cut -d'|' -f3)

		# Compare versions
		if version_lt "$current_version" "$LATEST_VERSION"; then
			echo -e "${RED}✗ OUTDATED (v${current_version} in ${source_file})${RESET}"
			INDIVIDUAL_OUTDATED=$((INDIVIDUAL_OUTDATED + 1))
			OUTDATED_COUNT=$((OUTDATED_COUNT + 1))

			# Fetch last commit date
			last_commit=$(gh api "repos/${repo}/commits/${branch}" --jq '.commit.committer.date' 2>/dev/null || echo "unknown")

			# Store for report
			echo "Individual Repositories|$repo|$current_version|$LATEST_VERSION|$source_file|$source_type|$branch|$last_commit" >>"$ORG_DATA_FILE"
			echo "$repo|$current_version|$source_file|$branch" >>"$OUTDATED_REPOS_FILE"
		else
			echo -e "${GREEN}✓ Up-to-date (v${current_version})${RESET}"
		fi
	done <"$REPO_LIST_FILE"

	# Summary for individual repositories
	echo
	echo -e "${YELLOW}${BOLD}📊 Summary for Individual Repositories:${RESET}"
	echo -e "   ${BLUE}Go repositories found:${RESET} ${INDIVIDUAL_GO_REPOS}"
	echo -e "   ${RED}Repositories with outdated golangci-lint:${RESET} ${INDIVIDUAL_OUTDATED}"
	if [ $INDIVIDUAL_GO_REPOS -gt 0 ]; then
		PERCENTAGE=$(awk "BEGIN { printf \"%.1f%%\", ($INDIVIDUAL_OUTDATED/$INDIVIDUAL_GO_REPOS)*100 }")
		echo -e "   ${BOLD}Outdated percentage:${RESET} ${PERCENTAGE}"
	fi
	echo -e "${BLUE}─────────────────────────────────────────────────────${RESET}"
	echo
fi

# Final summary
echo -e "${BOLD}${BLUE}📈 FINAL RESULTS:${RESET}"
echo -e "${BOLD}   Total repositories scanned:${RESET} ${TOTAL_REPOS}"
echo -e "${BOLD}   Repositories skipped (forks):${RESET} ${BLUE}${SKIPPED_FORKS}${RESET}"
echo -e "${BOLD}   Repositories skipped (abandoned):${RESET} ${BLUE}${SKIPPED_ABANDONED}${RESET}"
echo -e "${BOLD}   Repositories skipped (no go.mod):${RESET} ${BLUE}${SKIPPED_NOGOMOD}${RESET}"
echo -e "${BOLD}   Go repositories found:${RESET} ${TOTAL_GO_REPOS}"
echo -e "${BOLD}   Repositories with outdated golangci-lint:${RESET} ${RED}${OUTDATED_COUNT}${RESET}"

# Calculate percentage safely
ACTUAL_SCANNED=$((TOTAL_GO_REPOS))
if [ $ACTUAL_SCANNED -gt 0 ]; then
	PERCENTAGE=$(awk "BEGIN { printf \"%.1f%%\", ($OUTDATED_COUNT/$ACTUAL_SCANNED)*100 }")
else
	PERCENTAGE="N/A (no Go repositories found)"
fi
echo -e "${BOLD}   Outdated percentage:${RESET} ${PERCENTAGE}"
echo

# Detailed report and markdown generation
if [ $OUTDATED_COUNT -gt 0 ]; then
	echo -e "${RED}${BOLD}⚠️  DETAILED REPORT: REPOSITORIES WITH OUTDATED GOLANGCI-LINT${RESET}"
	echo -e "${RED}═══════════════════════════════════════════════════════════${RESET}"
	echo

	# Generate Markdown report
	echo "📝 Generating markdown report: $OUTPUT_MD"
	{
		echo "# Outdated GolangCI-Lint Report"
		echo ""
		echo "**Generated:** $(date '+%Y-%m-%d %H:%M:%S %Z')"
		echo ""
		echo "## Summary"
		echo ""
		echo "- **Total repositories scanned:** ${TOTAL_REPOS}"
		echo "- **Repositories skipped (forks):** ${SKIPPED_FORKS}"
		echo "- **Repositories skipped (abandoned - no commits in 6 months):** ${SKIPPED_ABANDONED}"
		echo "- **Repositories skipped (no go.mod):** ${SKIPPED_NOGOMOD}"
		echo "- **Go repositories checked:** ${ACTUAL_SCANNED}"
		echo "- **Repositories with outdated golangci-lint:** ${OUTDATED_COUNT}"
		echo "- **Outdated percentage:** ${PERCENTAGE}"
		echo "- **Latest golangci-lint version:** v${LATEST_VERSION}"
		echo ""
		echo "## Repositories with Outdated GolangCI-Lint"
		echo ""
		echo "| # | Repository | Current Version | Source File | GitHub URL |"
		echo "|---|------------|-----------------|-------------|------------|"

		counter=1
		sort -t'|' -k2 "$OUTDATED_REPOS_FILE" | while IFS='|' read -r repo version source branch; do
			echo "| $counter | \`$repo\` | v${version} | \`${source}\` | [View on GitHub](https://github.com/$repo) |"
			counter=$((counter + 1))
		done

		echo ""
		echo "---"
		echo ""
		echo "## How to Update"
		echo ""
		echo "### GitHub Actions (golangci-lint-action)"
		echo ""
		echo "Update the version in your workflow file (e.g., \`.github/workflows/golangci-lint.yml\`):"
		echo ""
		echo "\`\`\`yaml"
		echo "- name: golangci-lint"
		echo "  uses: golangci/golangci-lint-action@v${LATEST_VERSION}"
		echo "  with:"
		echo "    version: v${LATEST_VERSION}"
		echo "\`\`\`"
		echo ""
		echo "### Makefile"
		echo ""
		echo "Update the version variable in your Makefile:"
		echo ""
		echo "\`\`\`makefile"
		echo "GOLANGCI_LINT_VERSION = v${LATEST_VERSION}"
		echo "\`\`\`"
		echo ""
		echo "Or if using \`go install\`:"
		echo ""
		echo "\`\`\`makefile"
		echo "go install github.com/golangci/golangci-lint/cmd/golangci-lint@v${LATEST_VERSION}"
		echo "\`\`\`"
		echo ""
		echo "### Direct Installation"
		echo ""
		echo "\`\`\`bash"
		echo "go install github.com/golangci/golangci-lint/cmd/golangci-lint@v${LATEST_VERSION}"
		echo "\`\`\`"
		echo ""
		echo "## Resources"
		echo ""
		echo "- [GolangCI-Lint GitHub](https://github.com/golangci/golangci-lint)"
		echo "- [GolangCI-Lint Releases](https://github.com/golangci/golangci-lint/releases)"
		echo "- [GolangCI-Lint Documentation](https://golangci-lint.run/)"
		echo ""
	} >"$OUTPUT_MD"

	echo -e "${GREEN}✅ Markdown report saved to: $OUTPUT_MD${RESET}"
	echo

	# Display summary table
	printf "${BOLD}%-60s %-20s %-30s${RESET}\n" "Repository" "Current Version" "Source File"
	printf "%s\n" "────────────────────────────────────────────────────────────────────────────────────────────────────────────────────"

	sort -t'|' -k2 "$OUTDATED_REPOS_FILE" | while IFS='|' read -r repo version source branch; do
		printf "%-60s %-20s %-30s\n" "$repo" "v${version}" "$source"
	done

	echo
	echo -e "${YELLOW}${BOLD}💡 RECOMMENDATION:${RESET}"
	echo -e "${YELLOW}   Update golangci-lint to the latest version (v${LATEST_VERSION})${RESET}"
	echo -e "${YELLOW}   Reference: https://github.com/golangci/golangci-lint/releases${RESET}"
	echo
else
	echo -e "${GREEN}${BOLD}✅ Great! All Go repositories are using up-to-date golangci-lint versions${RESET}"
	echo

	# Generate empty report
	{
		echo "# Outdated GolangCI-Lint Report"
		echo ""
		echo "**Generated:** $(date '+%Y-%m-%d %H:%M:%S %Z')"
		echo ""
		echo "## Summary"
		echo ""
		echo "- **Total repositories scanned:** ${TOTAL_REPOS}"
		echo "- **Repositories skipped (forks):** ${SKIPPED_FORKS}"
		echo "- **Repositories skipped (abandoned - no commits in 6 months):** ${SKIPPED_ABANDONED}"
		echo "- **Repositories skipped (no go.mod):** ${SKIPPED_NOGOMOD}"
		echo "- **Go repositories checked:** ${ACTUAL_SCANNED}"
		echo "- **Repositories with outdated golangci-lint:** ${OUTDATED_COUNT}"
		echo "- **Latest golangci-lint version:** v${LATEST_VERSION}"
		echo ""
		echo "## ✅ Result"
		echo ""
		echo "**Great!** All scanned Go repositories are using up-to-date golangci-lint versions."
		echo ""
	} >"$OUTPUT_MD"

	echo "📝 Report saved to: $OUTPUT_MD"
	echo
fi

# Update tracking issue
if [ "$UPDATE_TRACKING" = true ]; then
	echo -e "${BLUE}${BOLD}📋 Updating Central Tracking Issue${RESET}"
	echo -e "${BLUE}─────────────────────────────────────────────────────${RESET}"
	echo -e "${BLUE}   Building issue body with ${OUTDATED_COUNT} outdated repositories...${RESET}"

	# Build the issue body
	ISSUE_BODY="# GolangCI-Lint Version Status Report

**Last Updated:** $(date -u '+%Y-%m-%d %H:%M:%S UTC')  
**Latest GolangCI-Lint Version:** \`v${LATEST_VERSION}\`  
**Reference:** [GolangCI-Lint Releases](https://github.com/golangci/golangci-lint/releases)

## Summary

- **Total Repositories Scanned:** ${TOTAL_REPOS}
- **Repositories Skipped (forks):** ${SKIPPED_FORKS}
- **Repositories Skipped (abandoned - no commits in 6 months):** ${SKIPPED_ABANDONED}
- **Repositories Skipped (no go.mod):** ${SKIPPED_NOGOMOD}
- **Go Repositories Checked:** ${ACTUAL_SCANNED}
- **Repositories with Outdated GolangCI-Lint:** ${OUTDATED_COUNT}
- **Outdated Percentage:** ${PERCENTAGE}

---

"

	if [ $OUTDATED_COUNT -gt 0 ]; then
		# Group by organization and create tables
		for ORG_NAME in "${ORGS[@]}" "Individual Repositories"; do
			# Check if this org has any outdated repos
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

				ISSUE_BODY+="**Repositories with Outdated GolangCI-Lint:** ${ORG_COUNT}

| Repository | Current Version | Latest Version | Source File | Last Updated |
|------------|-----------------|----------------|-------------|--------------|
"

				# Sort by last commit date (most recent first) and add each repo to the table
				echo "$ORG_REPOS" | sort -t'|' -k8 -r | while IFS='|' read -r org repo current latest source type branch last_commit; do
					# Extract just the repo name (without org prefix)
					repo_name="${repo##*/}"
					# Escape pipe characters in repo names if any
					repo_display=$(echo "$repo_name" | sed 's/|/\\|/g')
					# Format the date nicely
					if [ "$last_commit" != "unknown" ]; then
						last_commit_display=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_commit" "+%Y-%m-%d" 2>/dev/null || date -d "$last_commit" "+%Y-%m-%d" 2>/dev/null || echo "${last_commit:0:10}")
					else
						last_commit_display="Unknown"
					fi
					echo "| [\`${repo_display}\`](https://github.com/${repo}) | \`v${current}\` | \`v${latest}\` | \`${source}\` | ${last_commit_display} |"
				done >>"${ORG_DATA_FILE}.table"

				ISSUE_BODY+="$(cat "${ORG_DATA_FILE}.table")

"
				rm -f "${ORG_DATA_FILE}.table"
			fi
		done

		ISSUE_BODY+="---

## How to Update

### GitHub Actions (golangci-lint-action)

Update the version in your workflow file (e.g., \`.github/workflows/golangci-lint.yml\`):

\`\`\`yaml
- name: golangci-lint
  uses: golangci/golangci-lint-action@v${LATEST_VERSION}
  with:
    version: v${LATEST_VERSION}
\`\`\`

### Makefile

Update the version variable in your Makefile:

\`\`\`makefile
GOLANGCI_LINT_VERSION = v${LATEST_VERSION}
\`\`\`

Or if using \`go install\`:

\`\`\`makefile
go install github.com/golangci/golangci-lint/cmd/golangci-lint@v${LATEST_VERSION}
\`\`\`

### Direct Installation

\`\`\`bash
go install github.com/golangci/golangci-lint/cmd/golangci-lint@v${LATEST_VERSION}
\`\`\`

### Resources

- [GolangCI-Lint GitHub](https://github.com/golangci/golangci-lint)
- [GolangCI-Lint Releases](https://github.com/golangci/golangci-lint/releases)
- [GolangCI-Lint Documentation](https://golangci-lint.run/)

"
	else
		ISSUE_BODY+="## ✅ All Clear!

All scanned Go repositories are using up-to-date golangci-lint versions. Great work! 🎉

"
	fi

	ISSUE_BODY+="---

*This issue is automatically updated by the [golangci-lint-checker.sh](https://github.com/${TRACKING_REPO}/blob/main/scripts/golangci-lint-checker.sh) script.*"

	# Check if tracking issue exists
	echo -e "${BLUE}   Issue body built successfully${RESET}"
	echo -ne "   Checking for existing tracking issue... "
	EXISTING_ISSUE=$(gh issue list --repo "$TRACKING_REPO" --search "in:title \"${TRACKING_ISSUE_TITLE}\"" --state all --json number,title,state --jq ".[] | select(.title == \"${TRACKING_ISSUE_TITLE}\") | .number" | head -1)

	if [ -n "$EXISTING_ISSUE" ]; then
		echo -e "${GREEN}found (#${EXISTING_ISSUE})${RESET}"
		echo -ne "   Updating issue #${EXISTING_ISSUE}... "

		# Check if issue is closed and reopen it if there are outdated repos
		ISSUE_STATE=$(gh issue view "$EXISTING_ISSUE" --repo "$TRACKING_REPO" --json state --jq '.state')
		if [ "$ISSUE_STATE" = "CLOSED" ] && [ $OUTDATED_COUNT -gt 0 ]; then
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
fi

# Save updated caches
if [ -f "$CACHE_UPDATES" ] && [ -s "$CACHE_UPDATES" ]; then
	cat "$CACHE_UPDATES" "$CACHE_FILE" 2>/dev/null | sort -u >"${CACHE_FILE}.tmp"
	mv "${CACHE_FILE}.tmp" "$CACHE_FILE"
	NEW_CACHE_COUNT=$(wc -l <"$CACHE_UPDATES" | tr -d ' ')
	echo -e "${BLUE}💾 Non-Go repo cache updated: Added ${NEW_CACHE_COUNT} repositories${RESET}"
fi

if [ -f "$FORK_CACHE_UPDATES" ] && [ -s "$FORK_CACHE_UPDATES" ]; then
	cat "$FORK_CACHE_UPDATES" "$FORK_CACHE_FILE" 2>/dev/null | sort -u >"${FORK_CACHE_FILE}.tmp"
	mv "${FORK_CACHE_FILE}.tmp" "$FORK_CACHE_FILE"
	NEW_FORK_COUNT=$(wc -l <"$FORK_CACHE_UPDATES" | tr -d ' ')
	echo -e "${BLUE}🍴 Fork cache updated: Added ${NEW_FORK_COUNT} repositories${RESET}"
fi

if [ -f "$ABANDONED_CACHE_UPDATES" ] && [ -s "$ABANDONED_CACHE_UPDATES" ]; then
	cat "$ABANDONED_CACHE_UPDATES" "$ABANDONED_CACHE_FILE" 2>/dev/null | sort -u >"${ABANDONED_CACHE_FILE}.tmp"
	mv "${ABANDONED_CACHE_FILE}.tmp" "$ABANDONED_CACHE_FILE"
	NEW_ABANDONED_COUNT=$(wc -l <"$ABANDONED_CACHE_UPDATES" | tr -d ' ')
	echo -e "${BLUE}📋 Abandoned repo cache updated: Added ${NEW_ABANDONED_COUNT} repositories${RESET}"
fi

# Cleanup temporary files
rm -f "$OUTDATED_REPOS_FILE" "$ORG_DATA_FILE" "$CACHE_UPDATES" "$FORK_CACHE_UPDATES" "$ABANDONED_CACHE_UPDATES"

echo -e "${GREEN}${BOLD}✅ Scan completed successfully!${RESET}"
