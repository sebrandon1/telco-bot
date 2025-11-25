#!/bin/bash

#===============================================================================
# UBI IMAGE USAGE SCANNER
#===============================================================================
#
# DESCRIPTION:
#   This script scans GitHub organizations for repositories that use specific
#   UBI (Universal Base Image) versions in their Dockerfiles or Containerfiles.
#   Primary focus: identifying repositories using EOL UBI7 and UBI7-minimal images.
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
#   4. Internet connection to fetch repository data and Dockerfiles
#
# USAGE:
#   ./ubi-lookup.sh --version ubi7              # Check for EOL ubi7 usage
#   ./ubi-lookup.sh --version ubi7-minimal      # Check for EOL ubi7-minimal usage
#   ./ubi-lookup.sh --version ubi7 --org openshift  # Check specific org
#
# TRACKING ISSUE:
#   The script maintains a central tracking issue in the telco-bot repo
#   (https://github.com/redhat-best-practices-for-k8s/telco-bot/issues)
#   titled "Tracking UBI Image Usage - [VERSION]". This issue is automatically
#   created if it doesn't exist and updated with each run to show current status.
#
# CONFIGURATION:
#   Organizations:
#   - Use --org flag to scan a specific organization
#   - Without --org, scans all hardcoded default organizations
#   - Edit the ORGS array (line ~116) to change default organizations
#
#   Individual repositories:
#   - Specify individual repositories in ubi-repo-list.txt
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
#   - Table format output showing all repositories using the specified UBI version
#   - PR status check for open pull requests related to UBI migration
#   - Markdown report file (ubi-{version}-usage-report.md)
#   - Automatic creation/update of central tracking issue in telco-bot repo
#
# LIMITATIONS:
#   - Limited to 1000 repositories per organization (configurable via LIMIT)
#   - Only searches common Dockerfile/Containerfile locations
#   - Requires public access to container files or appropriate permissions
#===============================================================================

# Terminal colors (defined early for help text)
BOLD="\033[1m"
RESET="\033[0m"

# Function to show help
show_help() {
	echo -e "${BOLD}UBI Image Usage Scanner${RESET}"
	echo
	echo "Scans GitHub organizations for repositories using specific UBI (Universal Base Image) versions."
	echo
	echo -e "${BOLD}PRIMARY USE CASE:${RESET}"
	echo "    Track usage of EOL (End of Life) UBI7 images:"
	echo "    - ubi7 (EOL)"
	echo "    - ubi7-minimal (EOL)"
	echo
	echo -e "${BOLD}USAGE:${RESET}"
	echo "    $0 --version <ubi-version> [--org <organization>]"
	echo
	echo -e "${BOLD}OPTIONS:${RESET}"
	echo "    --version <version>    UBI version to search for (required)"
	echo "                          Common: ubi7, ubi7-minimal (both EOL)"
	echo "                          Others: ubi8, ubi9, ubi8-minimal, ubi9-minimal"
	echo
	echo "    --org <organization>   Scan only the specified organization (optional)"
	echo "                          If not provided, scans all default organizations:"
	echo "                          - redhat-best-practices-for-k8s"
	echo "                          - openshift"
	echo "                          - openshift-kni"
	echo "                          - redhat-openshift-ecosystem"
	echo "                          - redhatci"
	echo
	echo "    --no-issue            Skip GitHub issue creation/update"
	echo "                          (useful for CI/CD workflows)"
	echo
	echo "    -h, --help            Show this help message"
	echo
	echo -e "${BOLD}EXAMPLES:${RESET}"
	echo "    # Scan all default organizations for ubi7 (EOL)"
	echo "    $0 --version ubi7"
	echo
	echo "    # Scan for ubi7-minimal (EOL)"
	echo "    $0 --version ubi7-minimal"
	echo
	echo "    # Scan only openshift org for ubi7"
	echo "    $0 --version ubi7 --org openshift"
	echo
	echo -e "${BOLD}ADDITIONAL REPOSITORIES:${RESET}"
	echo "    You can also scan individual repositories by adding them to ubi-repo-list.txt"
	echo "    (one per line, in the format: owner/repo)"
	echo
	exit 0
}

# Parse command-line arguments
UBI_VERSION=""
SPECIFIC_ORG=""
SKIP_ISSUE_CREATION=false
while [[ $# -gt 0 ]]; do
	case $1 in
	-h | --help)
		show_help
		;;
	--version)
		UBI_VERSION="$2"
		shift 2
		;;
	--org)
		SPECIFIC_ORG="$2"
		shift 2
		;;
	--no-issue)
		SKIP_ISSUE_CREATION=true
		shift
		;;
	*)
		echo -e "\033[0;31m❌ ERROR: Unknown option: $1\033[0m"
		echo -e "\033[0;33m💡 Use -h or --help for usage information\033[0m"
		exit 1
		;;
	esac
done

# Validate that UBI version was provided
if [[ -z "$UBI_VERSION" ]]; then
	echo -e "\033[0;31m❌ ERROR: UBI version is required!\033[0m"
	echo -e "\033[0;33m💡 Use -h or --help for usage information\033[0m"
	exit 1
fi

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

# Start timing
START_TIME=$(date +%s)

# List of orgs to scan
if [[ -n "$SPECIFIC_ORG" ]]; then
	ORGS=("$SPECIFIC_ORG")
	echo -e "\033[0;36mℹ️  Scanning specific organization: ${SPECIFIC_ORG}\033[0m"
	echo
else
	ORGS=("redhat-best-practices-for-k8s" "openshift" "openshift-kni" "redhat-openshift-ecosystem" "redhatci")
	echo -e "\033[0;36mℹ️  Scanning all default organizations\033[0m"
	echo
fi

LIMIT=1000
FOUND_COUNT=0
TOTAL_REPOS=0
SKIPPED_FORKS=0
SKIPPED_NOCONTAINER=0
SKIPPED_ABANDONED=0

# Cache files
FORK_CACHE=".ubi-checker-forks.cache"
NOCONTAINER_CACHE=".ubi-checker-nocontainer.cache"
ABANDONED_CACHE=".ubi-checker-abandoned.cache"
OUTPUT_MD="ubi-${UBI_VERSION}-usage-report.md"

# Inactivity threshold (in days)
INACTIVITY_DAYS=180 # 6 months

# Terminal colors
GREEN="\033[0;32m"
RED="\033[0;31m"
BLUE="\033[0;34m"
YELLOW="\033[0;33m"
BOLD="\033[1m"
RESET="\033[0m"

# Tracking issue configuration
TRACKING_REPO="redhat-best-practices-for-k8s/telco-bot"
# Add EOL marker for ubi7 family images
if [[ "$UBI_VERSION" =~ ^ubi7 ]]; then
	TRACKING_ISSUE_TITLE="Tracking ${UBI_VERSION} Usage (EOL)"
else
	TRACKING_ISSUE_TITLE="Tracking ${UBI_VERSION} Usage"
fi

# Array to store repositories using the specified UBI version
declare -a UBI_REPOS

# Temporary file to store org-specific data for tracking issue (with last commit date and PR status)
ORG_DATA_FILE=$(mktemp)

# Common Dockerfile/Containerfile paths to check
CONTAINER_FILES=("Dockerfile" "Containerfile" "build/Dockerfile" "docker/Dockerfile" ".dockerfiles/Dockerfile" "dockerfiles/Dockerfile")

# Track other UBI versions found (using temp file for bash 3.x compatibility)
UBI_VERSIONS_TEMP=$(mktemp)

# Create empty cache files if they don't exist
touch "$FORK_CACHE" "$NOCONTAINER_CACHE" "$ABANDONED_CACHE"

# Load fork cache info if it exists
FORK_COUNT_LOADED=0
if [ -f "$FORK_CACHE" ] && [ -s "$FORK_CACHE" ]; then
	FORK_COUNT_LOADED=$(wc -l <"$FORK_CACHE" | tr -d ' ')
	echo "📋 Loading fork cache from $FORK_CACHE..."
	echo -e "${GREEN}✓ Loaded ${FORK_COUNT_LOADED} fork repositories to skip${RESET}"
	echo
fi

# Load no-container cache info if it exists
NOCONTAINER_COUNT_LOADED=0
if [ -f "$NOCONTAINER_CACHE" ] && [ -s "$NOCONTAINER_CACHE" ]; then
	NOCONTAINER_COUNT_LOADED=$(wc -l <"$NOCONTAINER_CACHE" | tr -d ' ')
	echo "📋 Loading no-container cache from $NOCONTAINER_CACHE..."
	echo -e "${GREEN}✓ Loaded ${NOCONTAINER_COUNT_LOADED} repositories without container files to skip${RESET}"
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

# Temporary file to track newly discovered no-container repos
NOCONTAINER_TEMP=$(mktemp)

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

# Helper function to check for open PRs related to UBI migration
check_ubi_pr() {
	local repo="$1"
	local ubi_ver="$2"

	# List all open PRs and grep for keywords in the title
	local pr_search=$(gh pr list --repo "$repo" --state open --json number,title,url --limit 50 2>/dev/null)

	if [[ $? -ne 0 || -z "$pr_search" || "$pr_search" == "[]" ]]; then
		echo "none"
		return
	fi

	# Filter PRs that have UBI-related keywords in the title
	local pr_links=$(echo "$pr_search" | jq -r '.[] | select(.title | test("ubi|UBI|universal base image|base image"; "i")) | "#" + (.number|tostring) + ";" + .url' | head -1)

	if [[ -n "$pr_links" ]]; then
		echo "$pr_links"
	else
		echo "none"
	fi
}

echo -e "${BLUE}${BOLD}🔍 SCANNING REPOSITORIES FOR ${UBI_VERSION} IMAGE USAGE${RESET}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${RESET}"
echo -e "${BLUE}📅 Skipping repos with no commits since: ${CUTOFF_DATE:0:10}${RESET}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${RESET}"

# Function to check if a file contains the UBI version
check_file_for_ubi() {
	local repo=$1
	local branch=$2
	local file_path=$3
	local raw_url="https://raw.githubusercontent.com/$repo/$branch/$file_path"
	local content

	content=$(curl -s -f "$raw_url")
	if [[ $? -eq 0 ]]; then
		# Check for FROM statements with the UBI version
		# Matches patterns like:
		# - FROM ubi7
		# - FROM ubi7/...
		# - FROM registry.access.redhat.com/ubi7
		# - FROM registry.access.redhat.com/ubi7/...
		# - FROM some.registry.com/.../ubi7
		if echo "$content" | grep -iE "^FROM[[:space:]]+.*${UBI_VERSION}([/:]|[[:space:]]|$)" >/dev/null; then
			return 0 # Found
		fi
	fi
	return 1 # Not found
}

# Function to find what UBI versions are in a file
find_other_ubi_versions() {
	local repo=$1
	local branch=$2
	local file_path=$3
	local raw_url="https://raw.githubusercontent.com/$repo/$branch/$file_path"
	local content
	local found_versions=""

	content=$(curl -s -f "$raw_url")
	if [[ $? -eq 0 && -n "$content" ]]; then
		# Extract all UBI versions from FROM statements
		# Match patterns like: FROM registry.../ubi8, FROM ubi9-minimal, etc.
		# The key is to extract ONLY the ubi version part
		local versions=""
		while IFS= read -r line; do
			# Check if line starts with FROM (case-insensitive)
			if echo "$line" | grep -qiE "^[[:space:]]*FROM"; then
				# Extract ubi version: ubi followed by digits, optionally followed by - and more alphanumeric
				local ubi_ver=$(echo "$line" | grep -ioE "ubi[0-9]+(-[a-z0-9]+)?" | head -1 | tr '[:upper:]' '[:lower:]')
				# Strict validation: must be ubi followed by at least one digit
				if [[ "$ubi_ver" =~ ^ubi[0-9]+(-[a-z0-9]+)?$ ]]; then
					versions="${versions}${ubi_ver}"$'\n'
				fi
			fi
		done <<<"$content"

		if [[ -n "$versions" ]]; then
			# Sort and get unique versions
			found_versions=$(echo "$versions" | grep -v '^$' | sort -u | tr '\n' ',' | sed 's/,$//')
		fi
	fi
	echo "$found_versions"
}

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
	ORG_FOUND=0

	# Use a separate file to store results to overcome the subshell limitation
	temp_results=$(mktemp)

	# Counter for progress display
	CURRENT_REPO=0

	while read -r repo branch; do
		CURRENT_REPO=$((CURRENT_REPO + 1))
		# Show a simple progress indicator with counter
		echo -ne "   ${BLUE}[${CURRENT_REPO}/${REPO_COUNT}]${RESET} 📂 ${repo} on branch ${branch}... "

		# Check if repo is in fork cache
		if is_in_cache "$repo" "$FORK_CACHE"; then
			echo -e "${BLUE}⏩ skipped (fork)${RESET}"
			SKIPPED_FORKS=$((SKIPPED_FORKS + 1))
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

		# Check if repo is in no-container cache
		if is_in_cache "$repo" "$NOCONTAINER_CACHE"; then
			echo -e "${BLUE}⏩ skipped (no container files)${RESET}"
			SKIPPED_NOCONTAINER=$((SKIPPED_NOCONTAINER + 1))
			continue
		fi

		found=false
		found_in_file=""
		other_versions=""
		has_container_file=false

		# Check each common container file location
		for file in "${CONTAINER_FILES[@]}"; do
			# Check if file exists
			raw_url="https://raw.githubusercontent.com/$repo/$branch/$file"
			if curl -s -f -I "$raw_url" >/dev/null 2>&1; then
				has_container_file=true
			fi

			if check_file_for_ubi "$repo" "$branch" "$file"; then
				found=true
				found_in_file="$file"
				break
			fi
			# If not found, check what other UBI versions exist
			if [[ -z "$other_versions" ]]; then
				other_versions=$(find_other_ubi_versions "$repo" "$branch" "$file")
			fi
		done

		# If no container files found, cache it
		if ! $has_container_file; then
			echo -e "${YELLOW}no container files (cached)${RESET}"
			echo "$repo" >>"$NOCONTAINER_TEMP"
			SKIPPED_NOCONTAINER=$((SKIPPED_NOCONTAINER + 1))
			continue
		fi

		if $found; then
			echo -e "${GREEN}✓ USES ${UBI_VERSION} in ${found_in_file}${RESET}"
			echo "$repo" >>"$temp_results"
			UBI_REPOS+=("$repo")

			# Fetch last commit date from default branch for tracking issue
			last_commit=$(gh api "repos/${repo}/commits/${branch}" --jq '.commit.committer.date' 2>/dev/null || echo "unknown")

			# Check for open PRs related to UBI migration
			pr_status=$(check_ubi_pr "$repo" "$UBI_VERSION")

			# Store for org-specific data: org|repo|branch|last_commit|pr_status
			echo "$ORG_NAME|$repo|$branch|$last_commit|$pr_status" >>"$ORG_DATA_FILE"
		else
			if [[ -n "$other_versions" ]]; then
				echo -e "${RED}✗ NO ${UBI_VERSION}${RESET} ${YELLOW}(found: ${other_versions})${RESET}"
				# Track other versions for summary
				IFS=',' read -ra VER_ARRAY <<<"$other_versions"
				for ver in "${VER_ARRAY[@]}"; do
					ver=$(echo "$ver" | tr -d ' ') # Trim whitespace
					# Only track valid UBI versions (must start with 'ubi' and have a number)
					if [[ "$ver" =~ ^ubi[0-9] ]]; then
						echo "$ver" >>"$UBI_VERSIONS_TEMP"
					fi
				done
			else
				echo -e "${RED}✗ NO ${UBI_VERSION} usage found${RESET}"
			fi
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
	echo -e "   ${GREEN}${ORG_FOUND}${RESET} repositories using ${UBI_VERSION}"
	echo -e "${BLUE}─────────────────────────────────────────────────────${RESET}"
	echo
done

# Scan individual repositories from ubi-repo-list.txt if it exists
REPO_LIST_FILE="ubi-repo-list.txt"
if [ -f "$REPO_LIST_FILE" ]; then
	echo -e "${YELLOW}${BOLD}👉 Individual Repositories from ${REPO_LIST_FILE}${RESET}"

	# Track results for individual repos
	INDIVIDUAL_FOUND=0
	INDIVIDUAL_COUNT=0

	# Use a separate file to store results
	temp_results=$(mktemp)

	# First pass: count valid repos
	TOTAL_INDIVIDUAL=0
	while IFS= read -r repo_input || [ -n "$repo_input" ]; do
		[[ -z "$repo_input" || "$repo_input" =~ ^[[:space:]]*(#|//) ]] && continue
		repo=$(echo "$repo_input" | sed -e 's|https://github.com/||' -e 's|github.com/||' -e 's|^[[:space:]]*||' -e 's|[[:space:]]*$||')
		[[ -z "$repo" ]] && continue
		TOTAL_INDIVIDUAL=$((TOTAL_INDIVIDUAL + 1))
	done <"$REPO_LIST_FILE"

	# Second pass: actually scan the repos
	while IFS= read -r repo_input || [ -n "$repo_input" ]; do
		# Skip empty lines and comments (# or //)
		[[ -z "$repo_input" || "$repo_input" =~ ^[[:space:]]*(#|//) ]] && continue

		# Normalize repo format: extract owner/repo from various formats
		repo=$(echo "$repo_input" | sed -e 's|https://github.com/||' -e 's|github.com/||' -e 's|^[[:space:]]*||' -e 's|[[:space:]]*$||')

		# Skip if still empty after normalization
		[[ -z "$repo" ]] && continue

		INDIVIDUAL_COUNT=$((INDIVIDUAL_COUNT + 1))

		# Check if repo is in fork cache
		if is_in_cache "$repo" "$FORK_CACHE"; then
			echo -ne "   ${BLUE}[${INDIVIDUAL_COUNT}/${TOTAL_INDIVIDUAL}]${RESET} 📂 ${repo}... "
			echo -e "${BLUE}⏩ skipped (fork)${RESET}"
			SKIPPED_FORKS=$((SKIPPED_FORKS + 1))
			continue
		fi

		# Get default branch for the repo
		echo -ne "   ${BLUE}[${INDIVIDUAL_COUNT}/${TOTAL_INDIVIDUAL}]${RESET} 📂 ${repo}... "
		branch=$(gh repo view "$repo" --json defaultBranchRef -q '.defaultBranchRef.name' 2>/dev/null)

		if [[ $? -ne 0 || -z "$branch" ]]; then
			echo -e "${RED}✗ Failed to fetch repo info${RESET}"
			continue
		fi

		echo -ne "on branch ${branch}... "

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

		# Check if repo is in no-container cache
		if is_in_cache "$repo" "$NOCONTAINER_CACHE"; then
			echo -e "${BLUE}⏩ skipped (no container files)${RESET}"
			SKIPPED_NOCONTAINER=$((SKIPPED_NOCONTAINER + 1))
			continue
		fi

		found=false
		found_in_file=""
		other_versions=""
		has_container_file=false

		# Check each common container file location
		for file in "${CONTAINER_FILES[@]}"; do
			# Check if file exists
			raw_url="https://raw.githubusercontent.com/$repo/$branch/$file"
			if curl -s -f -I "$raw_url" >/dev/null 2>&1; then
				has_container_file=true
			fi

			if check_file_for_ubi "$repo" "$branch" "$file"; then
				found=true
				found_in_file="$file"
				break
			fi
			# If not found, check what other UBI versions exist
			if [[ -z "$other_versions" ]]; then
				other_versions=$(find_other_ubi_versions "$repo" "$branch" "$file")
			fi
		done

		# If no container files found, cache it
		if ! $has_container_file; then
			echo -e "${YELLOW}no container files (cached)${RESET}"
			echo "$repo" >>"$NOCONTAINER_TEMP"
			SKIPPED_NOCONTAINER=$((SKIPPED_NOCONTAINER + 1))
			continue
		fi

		if $found; then
			echo -e "${GREEN}✓ USES ${UBI_VERSION} in ${found_in_file}${RESET}"
			echo "$repo" >>"$temp_results"
			UBI_REPOS+=("$repo")

			# Fetch last commit date from default branch for tracking issue
			last_commit=$(gh api "repos/${repo}/commits/${branch}" --jq '.commit.committer.date' 2>/dev/null || echo "unknown")

			# Check for open PRs related to UBI migration
			pr_status=$(check_ubi_pr "$repo" "$UBI_VERSION")

			# Store for org-specific data: org|repo|branch|last_commit|pr_status
			echo "Individual Repositories|$repo|$branch|$last_commit|$pr_status" >>"$ORG_DATA_FILE"
		else
			if [[ -n "$other_versions" ]]; then
				echo -e "${RED}✗ NO ${UBI_VERSION}${RESET} ${YELLOW}(found: ${other_versions})${RESET}"
				# Track other versions for summary
				IFS=',' read -ra VER_ARRAY <<<"$other_versions"
				for ver in "${VER_ARRAY[@]}"; do
					ver=$(echo "$ver" | tr -d ' ') # Trim whitespace
					# Only track valid UBI versions (must start with 'ubi' and have a number)
					if [[ "$ver" =~ ^ubi[0-9] ]]; then
						echo "$ver" >>"$UBI_VERSIONS_TEMP"
					fi
				done
			else
				echo -e "${RED}✗ NO ${UBI_VERSION} usage found${RESET}"
			fi
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
	echo -e "   ${GREEN}${INDIVIDUAL_FOUND}${RESET} repositories using ${UBI_VERSION} (out of ${INDIVIDUAL_COUNT} scanned)"
	echo -e "${BLUE}─────────────────────────────────────────────────────${RESET}"
	echo
fi

# Update no-container cache
if [ -f "$NOCONTAINER_TEMP" ] && [ -s "$NOCONTAINER_TEMP" ]; then
	cat "$NOCONTAINER_TEMP" >>"$NOCONTAINER_CACHE"
	sort -u "$NOCONTAINER_CACHE" -o "$NOCONTAINER_CACHE"
	NEW_NOCONTAINER=$(wc -l <"$NOCONTAINER_TEMP" | tr -d ' ')
	echo -e "${BLUE}💾 Updated no-container cache with ${NEW_NOCONTAINER} new entries${RESET}"
	echo
fi
rm -f "$NOCONTAINER_TEMP"

# Sort and deduplicate abandoned cache
if [ -f "$ABANDONED_CACHE" ] && [ -s "$ABANDONED_CACHE" ]; then
	sort -u "$ABANDONED_CACHE" -o "$ABANDONED_CACHE"
fi

# Final summary
echo -e "${BOLD}${BLUE}📈 FINAL RESULTS:${RESET}"
echo -e "${BOLD}   Total repositories scanned:${RESET} ${TOTAL_REPOS}"
echo -e "${BOLD}   Repositories skipped (forks):${RESET} ${BLUE}${SKIPPED_FORKS}${RESET}"
echo -e "${BOLD}   Repositories skipped (abandoned):${RESET} ${BLUE}${SKIPPED_ABANDONED}${RESET}"
echo -e "${BOLD}   Repositories skipped (no container files):${RESET} ${BLUE}${SKIPPED_NOCONTAINER}${RESET}"
echo -e "${BOLD}   Repositories using ${UBI_VERSION}:${RESET} ${GREEN}${FOUND_COUNT}${RESET}"

# Calculate percentage safely (avoid division by zero)
ACTUAL_SCANNED=$((TOTAL_REPOS - SKIPPED_FORKS - SKIPPED_ABANDONED - SKIPPED_NOCONTAINER))
if [ $ACTUAL_SCANNED -gt 0 ]; then
	PERCENTAGE=$(awk "BEGIN { printf \"%.1f%%\", ($FOUND_COUNT/$ACTUAL_SCANNED)*100 }")
else
	PERCENTAGE="N/A (no repositories scanned)"
fi
echo -e "${BOLD}   Usage percentage:${RESET} ${PERCENTAGE}"
echo

# Display table of repositories using the specified UBI version
if [ ${#UBI_REPOS[@]} -gt 0 ]; then
	echo -e "${GREEN}${BOLD}✅ REPOSITORIES USING ${UBI_VERSION}:${RESET}"
	echo -e "${GREEN}═══════════════════════════════════════════════════════════${RESET}"
	echo
	printf "${BOLD}%-60s${RESET} ${BOLD}%s${RESET}\n" "Repository" "URL"
	printf "%s\n" "─────────────────────────────────────────────────────────────────────────────────────────────"

	for repo in "${UBI_REPOS[@]}"; do
		printf "%-60s https://github.com/%s\n" "$repo" "$repo"
	done

	echo
	echo -e "${YELLOW}${BOLD}💡 RECOMMENDATION:${RESET}"
	echo -e "${YELLOW}   Consider migrating to a newer UBI version if using EOL images${RESET}"
	echo -e "${YELLOW}   Reference: https://access.redhat.com/articles/4238681${RESET}"
	echo

	# Generate Markdown report
	echo "📝 Generating markdown report: $OUTPUT_MD"
	{
		echo "# UBI ${UBI_VERSION} Usage Report"
		echo ""
		echo "**Generated:** $(date '+%Y-%m-%d %H:%M:%S %Z')"
		echo ""
		echo "## Summary"
		echo ""
		echo "- **Total repositories scanned:** ${TOTAL_REPOS}"
		echo "- **Repositories skipped (forks):** ${SKIPPED_FORKS}"
		echo "- **Repositories skipped (abandoned - no commits in 6 months):** ${SKIPPED_ABANDONED}"
		echo "- **Repositories skipped (no container files):** ${SKIPPED_NOCONTAINER}"
		echo "- **Repositories actually checked:** ${ACTUAL_SCANNED}"
		echo "- **Repositories using ${UBI_VERSION}:** ${FOUND_COUNT}"
		echo "- **Usage percentage:** ${PERCENTAGE}"
		echo ""
		echo "## Repositories Using ${UBI_VERSION}"
		echo ""
		echo "| # | Repository | GitHub URL |"
		echo "|---|------------|------------|"

		counter=1
		for repo in "${UBI_REPOS[@]}"; do
			echo "| $counter | \`$repo\` | [View on GitHub](https://github.com/$repo) |"
			counter=$((counter + 1))
		done

		echo ""
		echo "---"
		echo ""
		echo "## Migration Guide"
		echo ""
		echo "### Updating UBI Base Images"
		echo ""
		echo "1. **Update your Dockerfile/Containerfile:**"
		echo "   \`\`\`dockerfile"
		echo "   # Old"
		echo "   FROM registry.access.redhat.com/${UBI_VERSION}/..."
		echo "   "
		echo "   # New (example with ubi9)"
		echo "   FROM registry.access.redhat.com/ubi9/..."
		echo "   \`\`\`"
		echo ""
		echo "2. **Test your application:**"
		echo "   - Build the container image"
		echo "   - Run integration tests"
		echo "   - Verify all dependencies are compatible"
		echo ""
		echo "3. **Update CI/CD pipelines:**"
		echo "   - Update any hardcoded UBI version references"
		echo "   - Update documentation"
		echo ""
		echo "### Resources"
		echo ""
		echo "- [Red Hat Universal Base Images](https://www.redhat.com/en/blog/introducing-red-hat-universal-base-image)"
		echo "- [UBI Lifecycle](https://access.redhat.com/articles/4238681)"
		echo "- [Container Images](https://catalog.redhat.com/software/containers/explore)"
		echo ""
	} >"$OUTPUT_MD"

	echo -e "${GREEN}✅ Markdown report saved to: $OUTPUT_MD${RESET}"
	echo
else
	echo -e "${GREEN}${BOLD}✅ No repositories found using ${UBI_VERSION}${RESET}"
	echo

	# Generate empty report
	{
		echo "# UBI ${UBI_VERSION} Usage Report"
		echo ""
		echo "**Generated:** $(date '+%Y-%m-%d %H:%M:%S %Z')"
		echo ""
		echo "## Summary"
		echo ""
		echo "- **Total repositories scanned:** ${TOTAL_REPOS}"
		echo "- **Repositories skipped (forks):** ${SKIPPED_FORKS}"
		echo "- **Repositories skipped (abandoned - no commits in 6 months):** ${SKIPPED_ABANDONED}"
		echo "- **Repositories skipped (no container files):** ${SKIPPED_NOCONTAINER}"
		echo "- **Repositories actually checked:** ${ACTUAL_SCANNED}"
		echo "- **Repositories using ${UBI_VERSION}:** ${FOUND_COUNT}"
		echo ""
		echo "## ✅ Result"
		echo ""
		echo "**Great!** No repositories found using the \`${UBI_VERSION}\` image."
		echo ""
	} >"$OUTPUT_MD"

	echo "📝 Empty report saved to: $OUTPUT_MD"
	echo
fi

# Update tracking issue in telco-bot repo (unless --no-issue flag is set)
if [ "$SKIP_ISSUE_CREATION" = true ]; then
	echo
	echo -e "${YELLOW}${BOLD}ℹ️  Skipping GitHub issue creation (--no-issue flag set)${RESET}"
	echo
else
	echo
	echo -e "${BLUE}${BOLD}📋 Updating Central Tracking Issue${RESET}"
	echo -e "${BLUE}─────────────────────────────────────────────────────${RESET}"
	echo -e "${BLUE}   Building issue body with ${FOUND_COUNT} repositories using ${UBI_VERSION}...${RESET}"

# Build the issue body
EOL_WARNING=""
if [[ "$UBI_VERSION" =~ ^ubi7 ]]; then
	EOL_WARNING="
> **⚠️ WARNING: ${UBI_VERSION} is End of Life (EOL)**  
> This image version is no longer supported and should be migrated to a newer UBI version.

"
fi

ISSUE_BODY="# ${UBI_VERSION} Usage Report

${EOL_WARNING}**Last Updated:** $(date -u '+%Y-%m-%d %H:%M:%S UTC')  
**Reference:** [UBI Lifecycle](https://access.redhat.com/articles/4238681)

## Summary

- **Total Repositories Scanned:** ${TOTAL_REPOS}
- **Repositories Skipped (forks):** ${SKIPPED_FORKS}
- **Repositories Skipped (abandoned - no commits in 6 months):** ${SKIPPED_ABANDONED}
- **Repositories Skipped (no container files):** ${SKIPPED_NOCONTAINER}
- **Repositories Actually Checked:** ${ACTUAL_SCANNED}
- **Repositories Using ${UBI_VERSION}:** ${FOUND_COUNT}
- **Usage Percentage:** ${PERCENTAGE}

---

"

if [ $FOUND_COUNT -gt 0 ]; then
	# Group by organization and create tables
	for ORG_NAME in "${ORGS[@]}" "Individual Repositories"; do
		# Check if this org has any repos using the UBI version
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

			ISSUE_BODY+="**Repositories Using ${UBI_VERSION}:** ${ORG_COUNT}

| Repository | Branch | Last Updated | PR Status | GitHub Link |
|------------|--------|--------------|-----------|-------------|
"

			# Sort by last commit date (most recent first) and add each repo to the table
			echo "$ORG_REPOS" | sort -t'|' -k4 -r | while IFS='|' read -r org repo branch last_commit pr_status; do
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
				# Format PR status
				if [ "$pr_status" = "none" ] || [ -z "$pr_status" ]; then
					pr_display="—"
				else
					# Parse pr_status format: #123;https://github.com/org/repo/pull/123
					pr_number=$(echo "$pr_status" | cut -d';' -f1)
					pr_url=$(echo "$pr_status" | cut -d';' -f2)
					pr_display="[${pr_number}](${pr_url})"
				fi
				echo "| [\`${repo_display}\`](https://github.com/${repo}) | \`${branch}\` | ${last_commit_display} | ${pr_display} | [View Repository](https://github.com/${repo}) |"
			done >>"${ORG_DATA_FILE}.table"

			ISSUE_BODY+="$(cat "${ORG_DATA_FILE}.table")

"
			rm -f "${ORG_DATA_FILE}.table"
		fi
	done

	ISSUE_BODY+="---

## What to Do

"
	
	if [[ "$UBI_VERSION" =~ ^ubi7 ]]; then
		ISSUE_BODY+="**⚠️ URGENT: ${UBI_VERSION} is End of Life (EOL) and must be migrated.**

"
	else
		ISSUE_BODY+="Consider migrating to a newer UBI version if appropriate.

"
	fi
	
	ISSUE_BODY+="### Migration Steps

1. **Review the UBI lifecycle:**
   - Check [UBI Lifecycle Documentation](https://access.redhat.com/articles/4238681)
   - Determine if your current UBI version is EOL or approaching EOL

2. **Update your Dockerfile/Containerfile:**
   \`\`\`dockerfile
   # Old
   FROM registry.access.redhat.com/${UBI_VERSION}/...
   
   # New (example with ubi9)
   FROM registry.access.redhat.com/ubi9/...
   \`\`\`

3. **Test thoroughly:**
   - Build and test your container image
   - Run integration and E2E tests
   - Verify all dependencies work with the new base image

4. **Update documentation and CI/CD:**
   - Update any hardcoded version references
   - Update build pipelines
   - Document the change

### Resources

- [Red Hat Universal Base Images](https://www.redhat.com/en/blog/introducing-red-hat-universal-base-image)
- [UBI Lifecycle](https://access.redhat.com/articles/4238681)
- [Container Catalog](https://catalog.redhat.com/software/containers/explore)

"
else
	ISSUE_BODY+="## ✅ All Clear!

No repositories found using ${UBI_VERSION}. Great work! 🎉

"
fi

ISSUE_BODY+="---

*This issue is automatically updated by the [ubi-lookup.sh](https://github.com/${TRACKING_REPO}/blob/main/scripts/ubi-lookup.sh) script.*"

# Check if tracking issue exists
echo -e "${BLUE}   Issue body built successfully${RESET}"
echo -ne "   Checking for existing tracking issue... "
EXISTING_ISSUE=$(gh issue list --repo "$TRACKING_REPO" --search "in:title \"${TRACKING_ISSUE_TITLE}\"" --state all --json number,title,state --jq ".[] | select(.title == \"${TRACKING_ISSUE_TITLE}\") | .number" | head -1)

if [ -n "$EXISTING_ISSUE" ]; then
	echo -e "${GREEN}found (#${EXISTING_ISSUE})${RESET}"
	echo -ne "   Updating issue #${EXISTING_ISSUE}... "

	# Check if issue is closed and reopen it if there are repos using the UBI version
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

	# Cleanup temporary files
	rm -f "$ORG_DATA_FILE"
fi

# Show distribution of other UBI versions found
if [ -f "$UBI_VERSIONS_TEMP" ] && [ -s "$UBI_VERSIONS_TEMP" ]; then
	echo
	echo -e "${BOLD}${YELLOW}🔍 OTHER UBI VERSIONS FOUND:${RESET}"
	# Count occurrences, sort by count (descending), and display
	sort "$UBI_VERSIONS_TEMP" | uniq -c | sort -rn | while read -r count version; do
		# Additional validation: skip if version is empty or doesn't start with 'ubi' followed by a digit
		if [[ -n "$version" && "$version" =~ ^ubi[0-9] ]]; then
			echo -e "${BOLD}   ${version}:${RESET} ${count} repositories"
		fi
	done
fi

# Clean up temp file
[ -f "$UBI_VERSIONS_TEMP" ] && rm -f "$UBI_VERSIONS_TEMP"

# Calculate and display elapsed time
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
MINUTES=$((ELAPSED / 60))
SECONDS=$((ELAPSED % 60))

echo
echo -e "${BOLD}${BLUE}⏱️  TIME ELAPSED:${RESET}"
if [ $MINUTES -gt 0 ]; then
	echo -e "${BOLD}   ${MINUTES} minutes and ${SECONDS} seconds${RESET}"
else
	echo -e "${BOLD}   ${SECONDS} seconds${RESET}"
fi

echo -e "${GREEN}${BOLD}✅ Scan completed successfully!${RESET}"
echo
