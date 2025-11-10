#!/bin/bash

#===============================================================================
# GO VERSION CHECKER
#===============================================================================
#
# DESCRIPTION:
#   This script scans GitHub organizations for Go repositories and checks
#   whether their go.mod files specify an outdated Go version. A version is
#   considered outdated if it appears in the "Archived versions" section on
#   https://go.dev/dl/ rather than in the "Stable versions" section.
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
#   ./go-version-checker.sh [OPTIONS]
#
# OPTIONS:
#   --create-issues    Create GitHub issues on each outdated repository
#   --check-minor      Check patch versions too (e.g., flag 1.25.1 when 1.25.4 is latest)
#                      By default, only major versions are checked (e.g., 1.25 vs 1.24)
#   --no-tracking      Skip updating the central tracking issue in telco-bot repo
#   --clear-cache      Clear the cache of non-Go repositories and rescan everything
#   --help             Show this help message
#
# TRACKING ISSUE:
#   By default, the script maintains a central tracking issue in the telco-bot repo
#   (https://github.com/redhat-best-practices-for-k8s/telco-bot/issues)
#   titled "Tracking Out of Date Golang Versions". This issue is automatically
#   created if it doesn't exist and updated with each run to show current status.
#
# CONFIGURATION:
#   You can customize which organizations to scan by editing the ORGS array
#   below (line ~85). Add or remove organization names as needed:
#
#   ORGS=("your-org" "another-org" "third-org")
#
#   You can also specify individual repositories in go-version-repo-list.txt
#   (one per line). Supported formats:
#     - owner/repo
#     - github.com/owner/repo
#     - https://github.com/owner/repo
#
# OUTPUT:
#   The script provides:
#   - Real-time progress as it scans each repository
#   - Per-organization summary of findings
#   - Final detailed report of outdated repositories
#   - Color-coded output for easy reading
#   - Optional GitHub issue creation for outdated repos
#
# LIMITATIONS:
#   - Limited to 1000 repositories per organization (configurable via LIMIT)
#   - Requires public access to go.mod files or appropriate permissions
#   - Version comparison is based on the go.dev/dl/ page structure
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
echo

# Parse command line arguments
CREATE_ISSUES=false
CHECK_MINOR=false
UPDATE_TRACKING=true
CLEAR_CACHE=false
for arg in "$@"; do
	case $arg in
	--create-issues)
		CREATE_ISSUES=true
		shift
		;;
	--check-minor)
		CHECK_MINOR=true
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
# Restricted to single org for testing after rebase
# ORGS=("redhatci", "redhat-best-practices-for-k8s")
# Full list for production:
ORGS=("redhat-best-practices-for-k8s" "openshift-kni" "redhat-openshift-ecosystem" "redhatci" "openshift")

LIMIT=1000
OUTDATED_COUNT=0
TOTAL_GO_REPOS=0
TOTAL_REPOS=0

# Terminal colors
GREEN="\033[0;32m"
RED="\033[0;31m"
BLUE="\033[0;34m"
YELLOW="\033[0;33m"
BOLD="\033[1m"
RESET="\033[0m"

# Tracking issue configuration
TRACKING_REPO="redhat-best-practices-for-k8s/telco-bot"
TRACKING_ISSUE_TITLE="Tracking Out of Date Golang Versions"

# Cache file for non-Go repositories
CACHE_FILE=".go-version-checker.cache"

# Clear cache if requested
if [ "$CLEAR_CACHE" = true ]; then
	echo -e "${YELLOW}🗑️  Clearing cache...${RESET}"
	rm -f "$CACHE_FILE"
	echo -e "${GREEN}✅ Cache cleared${RESET}"
	echo
fi

# Load cache of non-Go repos
if [ -f "$CACHE_FILE" ]; then
	NON_GO_REPOS=$(cat "$CACHE_FILE")
	CACHE_SIZE=$(echo "$NON_GO_REPOS" | wc -l | tr -d ' ')
	echo -e "${BLUE}📦 Loaded cache: ${CACHE_SIZE} known non-Go repositories${RESET}"
else
	NON_GO_REPOS=""
fi

# Temporary files to store results
OUTDATED_REPOS_FILE=$(mktemp)
# Store org-specific data for tracking issue (with last commit date)
ORG_DATA_FILE=$(mktemp)
# Temporary cache updates
CACHE_UPDATES=$(mktemp)

# Fetch stable and archived versions from go.dev/dl/
echo -e "${BLUE}${BOLD}📡 Fetching Go version information from go.dev/dl/${RESET}"
echo -e "${BLUE}─────────────────────────────────────────────────────${RESET}"

GO_DL_PAGE=$(curl -s "https://go.dev/dl/")
if [[ $? -ne 0 ]]; then
	echo -e "${RED}❌ ERROR: Failed to fetch go.dev/dl/ page${RESET}"
	exit 1
fi

# Extract stable versions (everything before "Archived versions" section)
# Versions are in format go1.XX.YY
STABLE_VERSIONS=$(echo "$GO_DL_PAGE" | sed -n '0,/[Aa]rchived [Vv]ersions/p' | grep -oE 'go1\.[0-9]+(\.[0-9]+)?' | sort -u)
STABLE_COUNT=$(echo "$STABLE_VERSIONS" | wc -l | tr -d ' ')

# Extract major versions (e.g., go1.25 from go1.25.4) for default checking
STABLE_MAJOR_VERSIONS=$(echo "$STABLE_VERSIONS" | sed -E 's/^(go[0-9]+\.[0-9]+).*/\1/' | sort -u)

echo -e "${GREEN}✅ Found ${STABLE_COUNT} stable Go versions${RESET}"
echo -e "${BLUE}Stable versions:${RESET} $(echo $STABLE_VERSIONS | head -5 | tr '\n' ' ')..."
if [ "$CHECK_MINOR" = true ]; then
	echo -e "${YELLOW}⚙️  Mode: Checking patch versions (--check-minor enabled)${RESET}"
else
	echo -e "${YELLOW}⚙️  Mode: Checking major versions only (use --check-minor to check patches)${RESET}"
fi

# Fetch Kubernetes go.mod to see what version they use
echo -e "${BLUE}📦 Fetching Kubernetes Go versions...${RESET}"
K8S_GO_VERSION=$(curl -s "https://raw.githubusercontent.com/kubernetes/kubernetes/master/go.mod" | grep -E '^go [0-9]+\.[0-9]+' | awk '{print $2}' | head -1)
if [ -n "$K8S_GO_VERSION" ]; then
	echo -e "${GREEN}✅ Upstream Kubernetes is using Go ${K8S_GO_VERSION}${RESET}"
else
	echo -e "${YELLOW}⚠️  Unable to fetch upstream Kubernetes Go version${RESET}"
	K8S_GO_VERSION="unknown"
fi

# Fetch OpenShift Kubernetes fork go.mod
OPENSHIFT_K8S_GO_VERSION=$(curl -s "https://raw.githubusercontent.com/openshift/kubernetes/master/go.mod" | grep -E '^go [0-9]+\.[0-9]+' | awk '{print $2}' | head -1)
if [ -n "$OPENSHIFT_K8S_GO_VERSION" ]; then
	echo -e "${GREEN}✅ OpenShift Kubernetes is using Go ${OPENSHIFT_K8S_GO_VERSION}${RESET}"
else
	echo -e "${YELLOW}⚠️  Unable to fetch OpenShift Kubernetes Go version${RESET}"
	OPENSHIFT_K8S_GO_VERSION="unknown"
fi
echo

# Function to check if a version is stable
is_version_stable() {
	local version=$1
	# Normalize version format (remove 'go' prefix if present)
	version=$(echo "$version" | sed 's/^go//')

	if [ "$CHECK_MINOR" = true ]; then
		# Check full version including patch (e.g., 1.25.4)
		echo "$STABLE_VERSIONS" | grep -q "go${version}"
		return $?
	else
		# Check only major version (e.g., 1.25 from 1.25.4)
		local major_version=$(echo "$version" | sed -E 's/^([0-9]+\.[0-9]+).*/\1/')
		echo "$STABLE_MAJOR_VERSIONS" | grep -q "go${major_version}"
		return $?
	fi
}

# Function to extract Go version from go.mod content
extract_go_version() {
	local go_mod=$1
	# Look for 'go 1.XX' or 'go 1.XX.YY' line in go.mod
	echo "$go_mod" | grep -E '^go[[:space:]]+[0-9]+\.[0-9]+' | awk '{print $2}' | head -1
}

# Function to create or update a GitHub issue for outdated Go version
# Returns the issue number via echo
create_github_issue() {
	local repo=$1
	local current_version=$2
	local latest_stable=$3

	# Remove 'go' prefix from versions for display (go1.19 -> 1.19)
	local current_display="${current_version#go}"
	local latest_display="${latest_stable#go}"

	# If not checking minor versions, show only major version in title
	local latest_title_display="$latest_display"
	if [ "$CHECK_MINOR" = false ]; then
		# Extract major version (e.g., 1.25 from 1.25.4)
		latest_title_display=$(echo "$latest_display" | sed -E 's/^([0-9]+\.[0-9]+).*/\1/')
	fi

	local issue_title="Update Go version from ${current_display} to ${latest_title_display}"

	# Build Kubernetes version reference
	local k8s_version_text=""
	if [ "$K8S_GO_VERSION" != "unknown" ] || [ "$OPENSHIFT_K8S_GO_VERSION" != "unknown" ]; then
		k8s_version_text="
### Reference Examples"
		if [ "$K8S_GO_VERSION" != "unknown" ]; then
			k8s_version_text+="
- **Kubernetes Go Version**: \`${K8S_GO_VERSION}\` ([kubernetes/kubernetes/go.mod](https://github.com/kubernetes/kubernetes/blob/master/go.mod))"
		fi
		if [ "$OPENSHIFT_K8S_GO_VERSION" != "unknown" ]; then
			k8s_version_text+="
- **OpenShift Kubernetes Go Version**: \`${OPENSHIFT_K8S_GO_VERSION}\` ([openshift/kubernetes/go.mod](https://github.com/openshift/kubernetes/blob/master/go.mod))"
		fi
		k8s_version_text+="
"
	fi

	local issue_body="## Go Version Update Recommended

This repository is currently using Go version \`${current_display}\`, which is listed in the archived versions on [go.dev/dl/](https://go.dev/dl/).

### Current Status
- **Current Version**: \`${current_version}\`
- **Latest Stable**: \`${latest_stable}\`
- **Status**: ⚠️ Outdated (archived)
${k8s_version_text}
### Recommended Action
Please update the \`go.mod\` file to use a stable version of Go. The latest stable version is \`${latest_display}\`.

### Resources
- [Go Downloads](https://go.dev/dl/)
- [Go Release History](https://go.dev/doc/devel/release)

---
*[This issue was automatically generated by the Go Version Checker script.](https://github.com/${TRACKING_REPO}/blob/main/scripts/go-version-checker.sh)*"

	# Check if an issue already exists with a similar title (search both open and closed)
	echo -ne "      Checking for existing issue on ${repo}... " >&2
	local existing_issue=$(gh issue list --repo "$repo" --search "Update Go version" --state all --json number,title,state --jq ".[] | select(.title | test(\"Update Go version from\")) | \"\(.number)|\(.state)\"" | head -1)

	if [ -n "$existing_issue" ]; then
		local issue_number=$(echo "$existing_issue" | cut -d'|' -f1)
		local issue_state=$(echo "$existing_issue" | cut -d'|' -f2)

		echo -e "${YELLOW}found (#${issue_number}, ${issue_state})${RESET}" >&2
		echo -ne "      Updating issue #${issue_number}... " >&2

		if gh issue edit "$issue_number" --repo "$repo" --title "$issue_title" --body "$issue_body" &>/dev/null; then
			# Reopen if closed
			if [ "$issue_state" = "CLOSED" ]; then
				gh issue reopen "$issue_number" --repo "$repo" &>/dev/null
				echo -e "${GREEN}✓ Updated and reopened${RESET}" >&2
			else
				echo -e "${GREEN}✓ Updated${RESET}" >&2
			fi
			echo -e "      ${BLUE}→ https://github.com/${repo}/issues/${issue_number}${RESET}" >&2
			echo "$issue_number" # Return issue number
		else
			echo -e "${RED}✗ Failed to update${RESET}" >&2
			echo "" # Return empty string on failure
		fi
	else
		echo -e "${BLUE}not found${RESET}" >&2
		echo -ne "      Creating new issue... " >&2
		local issue_url=$(gh issue create --repo "$repo" --title "$issue_title" --body "$issue_body" 2>/dev/null)
		if [ $? -eq 0 ]; then
			local issue_number=$(echo "$issue_url" | grep -oE '[0-9]+$')
			echo -e "${GREEN}✓ Issue created${RESET}" >&2
			echo -e "      ${BLUE}→ ${issue_url}${RESET}" >&2
			echo "$issue_number" # Return issue number
		else
			echo -e "${RED}✗ Failed to create issue${RESET}" >&2
			echo "" # Return empty string on failure
		fi
	fi
}

# Function to close an existing Go version tracking issue when repo is up-to-date
close_github_issue() {
	local repo=$1
	local current_version=$2

	# Check if an issue exists
	local existing_issue=$(gh issue list --repo "$repo" --search "Update Go version" --state open --json number,title --jq ".[] | select(.title | test(\"Update Go version from\")) | .number" | head -1)

	if [ -n "$existing_issue" ]; then
		echo -ne " [Closing issue #${existing_issue}... " >&2
		if gh issue close "$existing_issue" --repo "$repo" &>/dev/null; then
			echo -e "${GREEN}✓ Closed]${RESET}" >&2
		else
			echo -e "${RED}✗ Failed]${RESET}" >&2
		fi
	fi
}

echo -e "${BLUE}${BOLD}🔍 SCANNING REPOSITORIES FOR OUTDATED GO VERSIONS${RESET}"
echo -e "${BLUE}─────────────────────────────────────────────────────${RESET}"

# Get latest stable version for issue creation
LATEST_STABLE=$(echo "$STABLE_VERSIONS" | tail -1 | sed 's/^go//')

for ORG_NAME in "${ORGS[@]}"; do
	echo -e "${YELLOW}${BOLD}👉 Organization: ${ORG_NAME}${RESET}"

	# Get all repos first
	echo -e "${BLUE}   Fetching repository list...${RESET}"
	REPOS=$(gh repo list "$ORG_NAME" --limit "$LIMIT" --json nameWithOwner,defaultBranchRef,isArchived -q '.[] | select(.isArchived == false) | .nameWithOwner + " " + .defaultBranchRef.name')
	REPO_COUNT=$(echo "$REPOS" | wc -l | tr -d ' ')
	TOTAL_REPOS=$((TOTAL_REPOS + REPO_COUNT))

	echo -e "${BLUE}   Found ${REPO_COUNT} active repositories to scan${RESET}"
	echo

	# Track results for this organization
	ORG_OUTDATED=0
	ORG_GO_REPOS=0

	while read -r repo branch; do
		# Skip empty lines
		[[ -z "$repo" ]] && continue

		# Show a simple progress indicator
		echo -ne "   📂 ${repo} on branch ${branch}... "

		# Check cache first
		if echo "$NON_GO_REPOS" | grep -q "^${repo}$"; then
			echo -e "${YELLOW}no go.mod (cached)${RESET}"
			continue
		fi

		# Fetch go.mod raw content from default branch
		raw_url="https://raw.githubusercontent.com/$repo/$branch/go.mod"
		go_mod=$(curl -s -f "$raw_url")

		if [[ $? -ne 0 ]]; then
			echo -e "${YELLOW}no go.mod${RESET}"
			# Add to cache
			echo "$repo" >>"$CACHE_UPDATES"
			continue
		fi

		ORG_GO_REPOS=$((ORG_GO_REPOS + 1))
		TOTAL_GO_REPOS=$((TOTAL_GO_REPOS + 1))

		# Extract Go version from go.mod
		go_version=$(extract_go_version "$go_mod")

		if [[ -z "$go_version" ]]; then
			echo -e "${YELLOW}⚠ No Go version specified${RESET}"
			continue
		fi

		# Check if version is stable
		if is_version_stable "$go_version"; then
			echo -ne "${GREEN}✓ Up-to-date (go${go_version})${RESET}"
			# Close any existing tracking issues since repo is now up-to-date
			close_github_issue "$repo" "go${go_version}"
			echo # New line after potential issue closing message
		else
			if [ "$CHECK_MINOR" = true ]; then
				echo -e "${RED}✗ OUTDATED (go${go_version})${RESET}"
			else
				# Extract major version for display
				major_version=$(echo "$go_version" | sed -E 's/^([0-9]+\.[0-9]+).*/\1/')
				echo -e "${RED}✗ OUTDATED (go${go_version} - major version ${major_version} is archived)${RESET}"
			fi
			ORG_OUTDATED=$((ORG_OUTDATED + 1))
			OUTDATED_COUNT=$((OUTDATED_COUNT + 1))

			# Fetch last commit date for sorting
			last_commit=$(gh repo view "$repo" --json pushedAt -q '.pushedAt' 2>/dev/null || echo "unknown")

			# Store for report (global and org-specific with last commit date)
			# Format: repo|version|branch|tracking_issue_number (tracking_issue_number added later if --create-issues is used)
			echo "$repo|$go_version|$branch" >>"$OUTDATED_REPOS_FILE"
			# Format: org|repo|version|branch|last_commit|tracking_issue_number (tracking_issue_number added later if --create-issues is used)
			echo "$ORG_NAME|$repo|$go_version|$branch|$last_commit|" >>"$ORG_DATA_FILE"
		fi
	done <<<"$REPOS"

	# Summary for this organization
	echo
	echo -e "${YELLOW}${BOLD}📊 Summary for ${ORG_NAME}:${RESET}"
	echo -e "   ${BLUE}Go repositories found:${RESET} ${ORG_GO_REPOS}"
	echo -e "   ${RED}Outdated repositories:${RESET} ${ORG_OUTDATED}"
	if [ $ORG_GO_REPOS -gt 0 ]; then
		PERCENTAGE=$(awk "BEGIN { printf \"%.1f%%\", ($ORG_OUTDATED/$ORG_GO_REPOS)*100 }")
		echo -e "   ${BOLD}Outdated percentage:${RESET} ${PERCENTAGE}"
	fi
	echo -e "${BLUE}─────────────────────────────────────────────────────${RESET}"
	echo
done

# Scan individual repositories from go-version-repo-list.txt if it exists
REPO_LIST_FILE="go-version-repo-list.txt"
if [ -f "$REPO_LIST_FILE" ]; then
	echo -e "${YELLOW}${BOLD}👉 Individual Repositories from ${REPO_LIST_FILE}${RESET}"

	# Track results for individual repos
	INDIVIDUAL_OUTDATED=0
	INDIVIDUAL_GO_REPOS=0

	while IFS= read -r repo_input || [ -n "$repo_input" ]; do
		# Skip empty lines and comments (# or //)
		[[ -z "$repo_input" || "$repo_input" =~ ^[[:space:]]*(#|//) ]] && continue

		# Normalize repo format: extract owner/repo from various formats
		repo=$(echo "$repo_input" | sed -e 's|https://github.com/||' -e 's|github.com/||' -e 's|^[[:space:]]*||' -e 's|[[:space:]]*$||')

		# Skip if still empty after normalization
		[[ -z "$repo" ]] && continue

		# Get default branch for the repo
		echo -ne "   📂 ${repo}... "

		# Check cache first
		if echo "$NON_GO_REPOS" | grep -q "^${repo}$"; then
			echo -e "${YELLOW}no go.mod (cached)${RESET}"
			continue
		fi

		branch=$(gh repo view "$repo" --json defaultBranchRef -q '.defaultBranchRef.name' 2>/dev/null)

		if [[ $? -ne 0 || -z "$branch" ]]; then
			echo -e "${RED}✗ Failed to fetch repo info${RESET}"
			continue
		fi

		echo -ne "on branch ${branch}... "

		# Fetch go.mod raw content from default branch
		raw_url="https://raw.githubusercontent.com/$repo/$branch/go.mod"
		go_mod=$(curl -s -f "$raw_url")

		if [[ $? -ne 0 ]]; then
			echo -e "${YELLOW}no go.mod${RESET}"
			# Add to cache
			echo "$repo" >>"$CACHE_UPDATES"
			continue
		fi

		INDIVIDUAL_GO_REPOS=$((INDIVIDUAL_GO_REPOS + 1))
		TOTAL_GO_REPOS=$((TOTAL_GO_REPOS + 1))

		# Extract Go version from go.mod
		go_version=$(extract_go_version "$go_mod")

		if [[ -z "$go_version" ]]; then
			echo -e "${YELLOW}⚠ No Go version specified${RESET}"
			continue
		fi

		# Check if version is stable
		if is_version_stable "$go_version"; then
			echo -ne "${GREEN}✓ Up-to-date (go${go_version})${RESET}"
			# Close any existing tracking issues since repo is now up-to-date
			close_github_issue "$repo" "go${go_version}"
			echo # New line after potential issue closing message
		else
			if [ "$CHECK_MINOR" = true ]; then
				echo -e "${RED}✗ OUTDATED (go${go_version})${RESET}"
			else
				# Extract major version for display
				major_version=$(echo "$go_version" | sed -E 's/^([0-9]+\.[0-9]+).*/\1/')
				echo -e "${RED}✗ OUTDATED (go${go_version} - major version ${major_version} is archived)${RESET}"
			fi
			INDIVIDUAL_OUTDATED=$((INDIVIDUAL_OUTDATED + 1))
			OUTDATED_COUNT=$((OUTDATED_COUNT + 1))
			TOTAL_REPOS=$((TOTAL_REPOS + 1))

			# Fetch last commit date for sorting
			last_commit=$(gh repo view "$repo" --json pushedAt -q '.pushedAt' 2>/dev/null || echo "unknown")

			# Store for report (global and org-specific with last commit date)
			echo "$repo|$go_version|$branch" >>"$OUTDATED_REPOS_FILE"
			echo "Individual Repositories|$repo|$go_version|$branch|$last_commit|" >>"$ORG_DATA_FILE"
		fi
	done <"$REPO_LIST_FILE"

	# Summary for individual repositories
	echo
	echo -e "${YELLOW}${BOLD}📊 Summary for Individual Repositories:${RESET}"
	echo -e "   ${BLUE}Go repositories found:${RESET} ${INDIVIDUAL_GO_REPOS}"
	echo -e "   ${RED}Outdated repositories:${RESET} ${INDIVIDUAL_OUTDATED}"
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
echo -e "${BOLD}   Go repositories found:${RESET} ${TOTAL_GO_REPOS}"
echo -e "${BOLD}   Repositories with outdated Go versions:${RESET} ${RED}${OUTDATED_COUNT}${RESET}"

# Calculate percentage safely (avoid division by zero)
if [ $TOTAL_GO_REPOS -gt 0 ]; then
	PERCENTAGE=$(awk "BEGIN { printf \"%.1f%%\", ($OUTDATED_COUNT/$TOTAL_GO_REPOS)*100 }")
else
	PERCENTAGE="N/A (no Go repositories found)"
fi
echo -e "${BOLD}   Outdated percentage:${RESET} ${PERCENTAGE}"
echo

# Detailed report of outdated repositories
if [ $OUTDATED_COUNT -gt 0 ]; then
	if [ "$CHECK_MINOR" = true ]; then
		echo -e "${RED}${BOLD}⚠️  DETAILED REPORT: REPOSITORIES WITH OUTDATED GO VERSIONS (Patch-Level Check)${RESET}"
	else
		echo -e "${RED}${BOLD}⚠️  DETAILED REPORT: REPOSITORIES WITH OUTDATED GO VERSIONS (Major Version Check)${RESET}"
	fi
	echo -e "${RED}─────────────────────────────────────────────────────${RESET}"
	echo

	# Sort and display
	sort "$OUTDATED_REPOS_FILE" | while IFS='|' read -r repo version branch; do
		echo -e "${BOLD}Repository:${RESET} ${repo}"
		echo -e "  ${RED}Current Version:${RESET} go${version} ${RED}(archived)${RESET}"
		echo -e "  ${GREEN}Latest Stable:${RESET} go${LATEST_STABLE}"
		echo -e "  ${BLUE}Branch:${RESET} ${branch}"
		echo -e "  ${BLUE}URL:${RESET} https://github.com/${repo}"
		echo
	done

	# Create GitHub issues if requested
	if [ "$CREATE_ISSUES" = true ]; then
		echo -e "${YELLOW}${BOLD}📝 Creating GitHub Issues for Outdated Repositories${RESET}"
		echo -e "${YELLOW}─────────────────────────────────────────────────────${RESET}"
		echo

		# Calculate cutoff date for "last year" (365 days ago)
		ONE_YEAR_AGO=$(date -u -v-365d "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "365 days ago" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")

		# Create a temporary file to store repo -> issue number mappings
		ISSUE_MAPPING=$(mktemp)

		# Use ORG_DATA_FILE to access last_commit timestamps
		sort -t'|' -k2 "$ORG_DATA_FILE" | while IFS='|' read -r org repo version branch last_commit tracking_issue; do
			# Only create issues for repos updated in the last year
			if [ -n "$ONE_YEAR_AGO" ] && [ "$last_commit" != "unknown" ] && [ "$last_commit" \< "$ONE_YEAR_AGO" ]; then
				echo -e "      ${YELLOW}⏩ Skipping ${repo} (last updated: ${last_commit:0:10}, inactive for >1 year)${RESET}" >&2
				continue
			fi

			issue_number=$(create_github_issue "$repo" "go${version}" "go${LATEST_STABLE}")
			if [ -n "$issue_number" ]; then
				echo "$repo|$issue_number" >>"$ISSUE_MAPPING"
			fi
		done

		# Update ORG_DATA_FILE with issue numbers
		if [ -f "$ISSUE_MAPPING" ] && [ -s "$ISSUE_MAPPING" ]; then
			ORG_DATA_TEMP=$(mktemp)
			while IFS='|' read -r org repo version branch last_commit tracking_issue; do
				# Look up issue number for this repo
				issue_num=$(grep "^${repo}|" "$ISSUE_MAPPING" | cut -d'|' -f2)
				if [ -n "$issue_num" ]; then
					echo "$org|$repo|$version|$branch|$last_commit|$issue_num" >>"$ORG_DATA_TEMP"
				else
					echo "$org|$repo|$version|$branch|$last_commit|$tracking_issue" >>"$ORG_DATA_TEMP"
				fi
			done <"$ORG_DATA_FILE"
			mv "$ORG_DATA_TEMP" "$ORG_DATA_FILE"
			rm -f "$ISSUE_MAPPING"
		fi

		echo
		echo -e "${GREEN}✅ Issue creation process completed${RESET}"
		echo
	else
		echo -e "${YELLOW}💡 Tip: Run with --create-issues flag to automatically create GitHub issues for outdated repositories${RESET}"
		echo
	fi
fi

# Update tracking issue
if [ "$UPDATE_TRACKING" = true ]; then
	echo -e "${BLUE}${BOLD}📋 Updating Central Tracking Issue${RESET}"
	echo -e "${BLUE}─────────────────────────────────────────────────────${RESET}"

	# Build the issue body
	# Add Kubernetes version references if available
	local k8s_ref=""
	if [ "$K8S_GO_VERSION" != "unknown" ]; then
		k8s_ref+="
**Kubernetes Go Version:** \`${K8S_GO_VERSION}\` ([kubernetes/kubernetes/go.mod](https://github.com/kubernetes/kubernetes/blob/master/go.mod))"
	fi
	if [ "$OPENSHIFT_K8S_GO_VERSION" != "unknown" ]; then
		k8s_ref+="
**OpenShift Kubernetes Go Version:** \`${OPENSHIFT_K8S_GO_VERSION}\` ([openshift/kubernetes/go.mod](https://github.com/openshift/kubernetes/blob/master/go.mod))"
	fi

	ISSUE_BODY="# Go Version Status Report

**Last Updated:** $(date -u '+%Y-%m-%d %H:%M:%S UTC')  
**Check Mode:** $([ "$CHECK_MINOR" = true ] && echo "Patch-level (including minor versions)" || echo "Major version only")  
**Latest Stable Go Version:** \`go${LATEST_STABLE}\`${k8s_ref}

## Summary

- **Total Repositories Scanned:** ${TOTAL_REPOS}
- **Go Repositories Found:** ${TOTAL_GO_REPOS}
- **Repositories with Outdated Versions:** ${OUTDATED_COUNT}
- **Outdated Percentage:** ${PERCENTAGE}

---

"

	if [ $OUTDATED_COUNT -gt 0 ]; then
		# Calculate cutoff date for "last year" (365 days ago)
		ONE_YEAR_AGO=$(date -u -v-365d "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "365 days ago" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")

		# Group by organization and create tables
		for ORG_NAME in "${ORGS[@]}" "Individual Repositories"; do
			# Check if this org has any outdated repos
			ORG_REPOS=$(grep "^${ORG_NAME}|" "$ORG_DATA_FILE" 2>/dev/null || true)

			if [ -n "$ORG_REPOS" ]; then
				ORG_COUNT=$(echo "$ORG_REPOS" | wc -l | tr -d ' ')

				# Count repos updated in the last year
				ACTIVE_COUNT=0
				if [ -n "$ONE_YEAR_AGO" ]; then
					while IFS='|' read -r org repo version branch last_commit tracking_issue; do
						if [ "$last_commit" != "unknown" ] && [ "$last_commit" \> "$ONE_YEAR_AGO" ]; then
							ACTIVE_COUNT=$((ACTIVE_COUNT + 1))
						fi
					done <<<"$ORG_REPOS"
				fi

				# Create clickable org header (skip for "Individual Repositories")
				if [ "$ORG_NAME" = "Individual Repositories" ]; then
					ISSUE_BODY+="## ${ORG_NAME}

"
				else
					ISSUE_BODY+="## [${ORG_NAME}](https://github.com/${ORG_NAME})

"
				fi

				ISSUE_BODY+="**Outdated Repositories:** ${ORG_COUNT}"

				if [ $ACTIVE_COUNT -gt 0 ]; then
					ISSUE_BODY+=" (${ACTIVE_COUNT} updated in the last year)"
				fi

				ISSUE_BODY+="

| Repository | Current Version | Branch | Last Updated | Tracking Issue |
|------------|----------------|--------|--------------|----------------|
"

				# Sort by last commit date (most recent first) and add each repo to the table
				echo "$ORG_REPOS" | sort -t'|' -k5 -r | while IFS='|' read -r org repo version branch last_commit tracking_issue; do
					# Extract just the repo name (without org prefix)
					repo_name="${repo##*/}"
					# Escape pipe characters in repo names if any
					repo_display=$(echo "$repo_name" | sed 's/|/\\|/g')
					# Remove 'go' prefix from version if present (go1.25.3 -> 1.25.3)
					version_display="${version#go}"
					# Format the date nicely (from ISO8601 to readable format)
					if [ "$last_commit" != "unknown" ]; then
						# Try macOS date format first, then Linux, then fall back to raw
						last_commit_display=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_commit" "+%Y-%m-%d" 2>/dev/null || date -d "$last_commit" "+%Y-%m-%d" 2>/dev/null || echo "${last_commit:0:10}")
					else
						last_commit_display="Unknown"
					fi
					# Add tracking issue link if available
					if [ -n "$tracking_issue" ]; then
						tracking_issue_link="[#${tracking_issue}](https://github.com/${repo}/issues/${tracking_issue})"
					else
						tracking_issue_link="—"
					fi
					echo "| [\`${repo_display}\`](https://github.com/${repo}) | \`${version_display}\` | \`${branch}\` | ${last_commit_display} | ${tracking_issue_link} |"
				done >>"${ORG_DATA_FILE}.table"

				ISSUE_BODY+="$(cat "${ORG_DATA_FILE}.table")

"
				rm -f "${ORG_DATA_FILE}.table"
			fi
		done

		ISSUE_BODY+="---

## What to Do

Repositories listed above are using Go versions that are in the archived section of [go.dev/dl/](https://go.dev/dl/). Consider updating to the latest stable version (\`${LATEST_STABLE}\`).

"
	else
		ISSUE_BODY+="## ✅ All Clear!

All scanned Go repositories are using up-to-date Go versions. Great work! 🎉

"
	fi

	ISSUE_BODY+="---

*This issue is automatically updated by the [go-version-checker.sh](https://github.com/${TRACKING_REPO}/blob/main/scripts/go-version-checker.sh) script.*"

	# Check if tracking issue exists
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

# Save updated cache
if [ -f "$CACHE_UPDATES" ] && [ -s "$CACHE_UPDATES" ]; then
	cat "$CACHE_UPDATES" "$CACHE_FILE" 2>/dev/null | sort -u >"${CACHE_FILE}.tmp"
	mv "${CACHE_FILE}.tmp" "$CACHE_FILE"
	NEW_CACHE_COUNT=$(wc -l <"$CACHE_UPDATES" | tr -d ' ')
	echo -e "${BLUE}💾 Cache updated: Added ${NEW_CACHE_COUNT} new non-Go repositories${RESET}"
fi

# Cleanup
rm -f "$OUTDATED_REPOS_FILE" "$ORG_DATA_FILE" "$CACHE_UPDATES"

echo -e "${GREEN}${BOLD}✅ Scan completed successfully!${RESET}"
