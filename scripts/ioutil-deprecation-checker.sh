#!/bin/bash

#===============================================================================
# IO/IOUTIL DEPRECATION SCANNER
#===============================================================================
#
# DESCRIPTION:
#   This script scans GitHub organizations for repositories that use the
#   deprecated io/ioutil package. The io/ioutil package was deprecated in
#   Go 1.16 (February 2021) and its functionality has been moved to the
#   io and os packages.
#
#   It identifies Go projects using io/ioutil by examining Go source files
#   for import statements and usage of the deprecated package.
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
#   4. Internet connection to fetch repository data and source files
#
# USAGE:
#   ./ioutil-deprecation-checker.sh
#
# TRACKING ISSUE:
#   The script maintains a central tracking issue in the telco-bot repo
#   (https://github.com/redhat-best-practices-for-k8s/telco-bot/issues)
#   titled "Tracking Deprecated io/ioutil Package Usage". This issue is
#   automatically created if it doesn't exist and updated with each run.
#
# CONFIGURATION:
#   You can customize which organizations to scan by editing the ORGS array
#   below (line ~85). Add or remove organization names as needed:
#
#   ORGS=("your-org" "another-org" "third-org")
#
# OUTPUT:
#   The script provides:
#   - Real-time progress as it scans each repository
#   - Per-organization summary of findings
#   - Final summary with total counts and usage percentage
#   - Color-coded output for easy reading
#   - Table format output showing all repositories using deprecated io/ioutil
#   - Markdown report file (ioutil-usage-report.md)
#   - Automatic creation/update of central tracking issue in telco-bot repo
#
# LIMITATIONS:
#   - Limited to 1000 repositories per organization (configurable via LIMIT)
#   - Scans a sample of Go files per repository (not exhaustive)
#   - Requires public access to source files or appropriate permissions
#
# REFERENCE:
#   - Go 1.16 Release Notes: https://go.dev/doc/go1.16
#   - Migration guide included in script output
#===============================================================================

# Terminal colors
GREEN="\033[0;32m"
RED="\033[0;31m"
BLUE="\033[0;34m"
YELLOW="\033[0;33m"
BOLD="\033[1m"
RESET="\033[0m"

# Parse command line arguments
FORCE_REFRESH=false
for arg in "$@"; do
	if [ "$arg" = "--force" ] || [ "$arg" = "-f" ]; then
		FORCE_REFRESH=true
	elif [ "$arg" = "--help" ] || [ "$arg" = "-h" ]; then
		echo "Usage: $0 [OPTIONS]"
		echo ""
		echo "Options:"
		echo "  --force, -f    Force refresh cache (ignore cache age)"
		echo "  --help, -h     Show this help message"
		echo ""
		exit 0
	fi
done

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

LIMIT=1000
FOUND_COUNT=0
TOTAL_REPOS=0
SKIPPED_FORKS=0
SKIPPED_NOGO=0
SKIPPED_ABANDONED=0
SKIPPED_TRACKING_ISSUE=0

# Cache files
FORK_CACHE=".ioutil-checker-forks.cache"
NOGO_CACHE=".ioutil-checker-nogo.cache"
ABANDONED_CACHE=".ioutil-checker-abandoned.cache"
RESULTS_CACHE=".ioutil-checker-results.json"
OUTPUT_MD="ioutil-usage-report.md"

# Inactivity threshold (in days)
INACTIVITY_DAYS=180 # 6 months

# Cache age threshold (in seconds) - 6 hours
CACHE_MAX_AGE=$((6 * 60 * 60))

# Create empty cache files if they don't exist
touch "$FORK_CACHE" "$NOGO_CACHE" "$ABANDONED_CACHE"

#===============================================================================
# HELPER FUNCTIONS - Must be defined before use
#===============================================================================

# Helper function to check if repo is in cache
is_in_cache() {
	local repo="$1"
	local cache_file="$2"
	grep -Fxq "$repo" "$cache_file" 2>/dev/null
}

# Helper function to check if results cache is valid (less than 6 hours old)
is_cache_valid() {
	if [ ! -f "$RESULTS_CACHE" ]; then
		return 1
	fi

	if [ "$FORCE_REFRESH" = true ]; then
		return 1
	fi

	# Get cache timestamp
	local cache_timestamp=$(jq -r '.timestamp // empty' "$RESULTS_CACHE" 2>/dev/null)
	if [ -z "$cache_timestamp" ]; then
		return 1
	fi

	# Convert to epoch seconds (cross-platform compatible)
	local cache_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$cache_timestamp" "+%s" 2>/dev/null || date -d "$cache_timestamp" "+%s" 2>/dev/null)
	local now_epoch=$(date "+%s")

	if [ -z "$cache_epoch" ]; then
		return 1
	fi

	local age=$((now_epoch - cache_epoch))

	if [ $age -lt $CACHE_MAX_AGE ]; then
		return 0
	else
		return 1
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

# Load no-Go cache info if it exists
NOGO_COUNT_LOADED=0
if [ -f "$NOGO_CACHE" ] && [ -s "$NOGO_CACHE" ]; then
	NOGO_COUNT_LOADED=$(wc -l <"$NOGO_CACHE" | tr -d ' ')
	echo "📋 Loading no-Go cache from $NOGO_CACHE..."
	echo -e "${GREEN}✓ Loaded ${NOGO_COUNT_LOADED} non-Go repositories to skip${RESET}"
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

# Check results cache validity
CACHE_VALID=false
if is_cache_valid; then
	CACHE_VALID=true
	CACHED_REPO_COUNT=$(jq '.repositories | length' "$RESULTS_CACHE" 2>/dev/null || echo "0")
	CACHE_TIMESTAMP=$(jq -r '.timestamp' "$RESULTS_CACHE" 2>/dev/null || echo "unknown")
	echo "📋 Loading results cache from $RESULTS_CACHE..."
	echo -e "${GREEN}✓ Cache is valid (age < 6 hours)${RESET}"
	echo -e "${GREEN}✓ Loaded ${CACHED_REPO_COUNT} cached results from ${CACHE_TIMESTAMP}${RESET}"
	echo
else
	if [ -f "$RESULTS_CACHE" ]; then
		if [ "$FORCE_REFRESH" = true ]; then
			echo "📋 Results cache exists but --force flag set, ignoring cache..."
		else
			echo "📋 Results cache is stale (age > 6 hours), will refresh..."
		fi
	else
		echo "📋 No results cache found, will scan all repositories..."
	fi
	echo
fi

# Calculate cutoff date (6 months ago)
CUTOFF_DATE=$(date -u -v-${INACTIVITY_DAYS}d "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "${INACTIVITY_DAYS} days ago" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")

if [ -z "$CUTOFF_DATE" ]; then
	echo -e "${RED}❌ ERROR: Unable to calculate cutoff date${RESET}" >&2
	exit 1
fi

# Temporary file to track newly discovered non-Go repos
NOGO_TEMP=$(mktemp)

# Helper function to get cached result for a repository
get_cached_result() {
	local repo="$1"

	if [ ! -f "$RESULTS_CACHE" ]; then
		echo "unknown"
		return
	fi

	# Escape repo name for jq
	local escaped_repo=$(echo "$repo" | sed 's/\//\\\//g')

	# Get the cached result
	local result=$(jq -r ".repositories[\"$repo\"] // empty" "$RESULTS_CACHE" 2>/dev/null)

	if [ -z "$result" ] || [ "$result" = "null" ]; then
		echo "unknown"
		return
	fi

	echo "$result"
}

# Helper function to update cache with result
update_cache_result() {
	local repo="$1"
	local uses_ioutil="$2"
	local api_success="$3"
	local error="${4:-}"

	local timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

	# Create cache file if it doesn't exist
	if [ ! -f "$RESULTS_CACHE" ]; then
		echo '{"timestamp":"'$timestamp'","repositories":{}}' >"$RESULTS_CACHE"
	fi

	# Build the result object
	local result_obj="{\"uses_ioutil\":$uses_ioutil,\"api_success\":$api_success,\"last_checked\":\"$timestamp\""
	if [ -n "$error" ]; then
		result_obj="${result_obj},\"error\":\"$error\""
	fi
	result_obj="${result_obj}}"

	# Update the cache
	local temp_cache=$(mktemp)
	jq ".repositories[\"$repo\"] = $result_obj" "$RESULTS_CACHE" >"$temp_cache" 2>/dev/null && mv "$temp_cache" "$RESULTS_CACHE" || rm -f "$temp_cache"
}

# Helper function to save cache timestamp
update_cache_timestamp() {
	local timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

	if [ -f "$RESULTS_CACHE" ]; then
		local temp_cache=$(mktemp)
		jq ".timestamp = \"$timestamp\"" "$RESULTS_CACHE" >"$temp_cache" 2>/dev/null && mv "$temp_cache" "$RESULTS_CACHE" || rm -f "$temp_cache"
	fi
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

# Helper function to check for io/ioutil usage in a repository
check_ioutil_usage() {
	local repo="$1"
	local branch="$2"

	# First check if repo has go.mod - if not, it's not a modern Go project
	local raw_url="https://raw.githubusercontent.com/$repo/$branch/go.mod"
	if ! curl -s -f -I "$raw_url" >/dev/null 2>&1; then
		# No go.mod found
		return 3
	fi

	# Use GitHub's code search API to look for io/ioutil imports
	# Search for: "io/ioutil" in Go files (excluding vendor directories)
	# Note: Code Search API has strict rate limits (10 requests/min for authenticated users)
	local search_result=$(gh api "search/code?q=io/ioutil+repo:${repo}+language:go+-path:vendor" 2>&1)
	local api_status=$?

	# Check if we got a rate limit error
	if echo "$search_result" | grep -q "rate limit exceeded"; then
		# Rate limit hit, return error code
		return 2
	fi

	if [[ $api_status -ne 0 ]]; then
		# API call failed for other reasons
		return 2
	fi

	# Extract total_count from the result
	local count=$(echo "$search_result" | jq -r '.total_count // 0' 2>/dev/null)

	# Validate that count is a number
	if ! [[ "$count" =~ ^[0-9]+$ ]]; then
		# Invalid response, return error
		return 2
	fi

	if [[ "$count" -gt 0 ]]; then
		return 0 # Found io/ioutil usage
	else
		return 1 # No io/ioutil usage found
	fi
}

# Helper function to check for PRs related to ioutil migration (open, closed, or merged)
check_ioutil_pr() {
	local repo="$1"

	# List all PRs (open, closed, merged) and filter for ioutil-related keywords
	# Check both open and closed PRs (closed includes merged)
	local pr_search=$(gh pr list --repo "$repo" --state all --json number,title,url,state,mergedAt --limit 100 2>/dev/null)

	if [[ $? -ne 0 || -z "$pr_search" || "$pr_search" == "[]" ]]; then
		echo "none"
		return
	fi

	# Filter PRs that have ioutil-related keywords in the title
	# Return format: #123;URL;STATUS;NEEDS_REBASE (STATUS = open/merged/closed)
	local pr_info=$(echo "$pr_search" | jq -r '.[] | select(.title | test("ioutil|io/ioutil"; "i")) | 
		if .mergedAt != null then
			"#" + (.number|tostring) + ";" + .url + ";merged;no"
		elif .state == "OPEN" then
			"#" + (.number|tostring) + ";" + .url + ";open;unknown"
		else
			"#" + (.number|tostring) + ";" + .url + ";closed;no"
		end' | head -1)

	if [[ -n "$pr_info" ]]; then
		# If the PR is open, check if it needs a rebase
		local pr_state=$(echo "$pr_info" | cut -d';' -f3)
		if [ "$pr_state" = "open" ]; then
			local pr_number=$(echo "$pr_info" | cut -d';' -f1 | sed 's/#//')
			local pr_url=$(echo "$pr_info" | cut -d';' -f2)

			# Check mergeable status - get both mergeable and mergeStateStatus
			local pr_details=$(gh pr view "$pr_number" --repo "$repo" --json mergeable,mergeStateStatus 2>/dev/null)
			local mergeable=$(echo "$pr_details" | jq -r '.mergeable // "UNKNOWN"')
			local merge_state=$(echo "$pr_details" | jq -r '.mergeStateStatus // "UNKNOWN"')

			# Determine if rebase is needed based on mergeable status and merge state
			local needs_rebase="unknown"
			if [ "$merge_state" = "BEHIND" ] || [ "$mergeable" = "CONFLICTING" ]; then
				needs_rebase="yes"
			elif [ "$mergeable" = "MERGEABLE" ]; then
				needs_rebase="no"
			fi

			echo "#${pr_number};${pr_url};open;${needs_rebase}"
		else
			echo "$pr_info"
		fi
	else
		echo "none"
	fi
}

# Tracking issue configuration
TRACKING_REPO="redhat-best-practices-for-k8s/telco-bot"
TRACKING_ISSUE_TITLE="Tracking Deprecated io/ioutil Package Usage"

# Array to store repositories using deprecated io/ioutil
declare -a DEPRECATED_REPOS

# Temporary file to store org-specific data for tracking issue
ORG_DATA_FILE=$(mktemp)

# Temporary file to store tracking issue cache
TRACKING_ISSUE_CACHE=$(mktemp)

# Helper function to fetch and parse tracking issue
fetch_tracking_issue() {
	echo -e "${BLUE}📋 Fetching tracking issue to reduce API calls...${RESET}"

	# Get the tracking issue number
	local issue_number=$(gh issue list --repo "$TRACKING_REPO" --search "in:title \"${TRACKING_ISSUE_TITLE}\"" --state all --json number,title --jq ".[] | select(.title == \"${TRACKING_ISSUE_TITLE}\") | .number" | head -1)

	if [ -z "$issue_number" ]; then
		echo -e "${YELLOW}   ⚠️  Tracking issue not found, will perform full scan${RESET}"
		return 1
	fi

	# Fetch the issue body
	local issue_body=$(gh issue view "$issue_number" --repo "$TRACKING_REPO" --json body --jq '.body')

	if [ -z "$issue_body" ]; then
		echo -e "${YELLOW}   ⚠️  Could not fetch issue body, will perform full scan${RESET}"
		return 1
	fi

	# Parse the markdown tables to extract repo names and last updated dates
	# Format: | [repo-name](url) | branch | 2025-11-24 | PR Status | Link |
	echo "$issue_body" | grep -E '^\|.*github\.com.*\|.*\|.*[0-9]{4}-[0-9]{2}-[0-9]{2}.*\|' | while IFS='|' read -r _ repo_col branch_col date_col _; do
		# Extract repo name from markdown link [name](url)
		local repo=$(echo "$repo_col" | sed -n 's/.*github\.com\/\([^)]*\).*/\1/p' | tr -d ' `[]')
		# Extract date (format: 2025-11-24)
		local last_updated=$(echo "$date_col" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)

		if [ -n "$repo" ] && [ -n "$last_updated" ]; then
			echo "${repo}|${last_updated}" >>"$TRACKING_ISSUE_CACHE"
		fi
	done

	if [ -f "$TRACKING_ISSUE_CACHE" ] && [ -s "$TRACKING_ISSUE_CACHE" ]; then
		local cached_count=$(wc -l <"$TRACKING_ISSUE_CACHE" | tr -d ' ')
		echo -e "${GREEN}   ✓ Loaded ${cached_count} repositories from tracking issue${RESET}"
		echo -e "${BLUE}   Repos updated in last 24h will be assumed to still use io/ioutil${RESET}"
		return 0
	else
		echo -e "${YELLOW}   ⚠️  No repos found in tracking issue, will perform full scan${RESET}"
		return 1
	fi
}

# Helper function to check if repo is in tracking issue and recently updated
is_recently_confirmed() {
	local repo="$1"

	if [ ! -f "$TRACKING_ISSUE_CACHE" ] || [ ! -s "$TRACKING_ISSUE_CACHE" ]; then
		return 1
	fi

	# Look for the repo in the cache
	local cached_entry=$(grep "^${repo}|" "$TRACKING_ISSUE_CACHE" | head -1)

	if [ -z "$cached_entry" ]; then
		return 1
	fi

	# Extract the date
	local last_updated=$(echo "$cached_entry" | cut -d'|' -f2)

	# Validate the date format
	if [ -z "$last_updated" ] || ! [[ "$last_updated" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
		# Invalid or missing date, don't use the cache
		return 1
	fi

	# Calculate 24 hours ago in UTC
	local cutoff_time=$(date -u -v-24H "+%Y-%m-%d" 2>/dev/null || date -u -d "24 hours ago" "+%Y-%m-%d" 2>/dev/null)

	if [ -z "$cutoff_time" ]; then
		# If date calculation fails, don't use the cache
		return 1
	fi

	# Compare dates (using [[ ]] for string comparison with YYYY-MM-DD format)
	# Lexicographic comparison works for YYYY-MM-DD: if NOT less than cutoff, it's >= cutoff
	if ! [[ "$last_updated" < "$cutoff_time" ]]; then
		return 0 # Recently confirmed (within last 24h)
	else
		return 1 # Too old, need to recheck
	fi
}

echo -e "${BLUE}${BOLD}🔍 SCANNING REPOSITORIES FOR DEPRECATED IO/IOUTIL USAGE${RESET}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${RESET}"
echo -e "${YELLOW}⚠️  Note: io/ioutil was deprecated in Go 1.16 (February 2021)${RESET}"
echo -e "${YELLOW}    Functionality moved to io and os packages${RESET}"
echo -e "${BLUE}───────────────────────────────────────────────────────────${RESET}"
echo -e "${BLUE}📅 Skipping repos with no commits since: ${CUTOFF_DATE:0:10}${RESET}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${RESET}"
echo

# Fetch tracking issue to reduce API calls
fetch_tracking_issue
echo

for ORG_NAME in "${ORGS[@]}"; do
	echo -e "${YELLOW}${BOLD}👉 Organization: ${ORG_NAME}${RESET}"

	# Get all repos first
	echo -e "${BLUE}   Fetching repository list...${RESET}"
	REPOS=$(gh repo list "$ORG_NAME" --limit "$LIMIT" --json nameWithOwner,defaultBranchRef,isArchived,primaryLanguage -q '.[] | select(.isArchived == false) | select(.primaryLanguage.name == "Go") | .nameWithOwner + " " + .defaultBranchRef.name')
	REPO_COUNT=$(echo "$REPOS" | grep -v '^$' | wc -l | tr -d ' ')

	if [ "$REPO_COUNT" -eq 0 ]; then
		echo -e "${BLUE}   No active Go repositories found${RESET}"
		echo
		continue
	fi

	TOTAL_REPOS=$((TOTAL_REPOS + REPO_COUNT))

	echo -e "${BLUE}   Found ${REPO_COUNT} active Go repositories to scan${RESET}"
	echo

	# Track results for this organization
	ORG_FOUND=0

	# Use a separate file to store results to overcome the subshell limitation
	temp_results=$(mktemp)

	while read -r repo branch; do
		# Skip empty lines
		[[ -z "$repo" ]] && continue

		# Show a simple progress indicator
		echo -ne "   📂 ${repo} on branch ${branch}... "

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

		# Check if repo is in no-Go cache
		if is_in_cache "$repo" "$NOGO_CACHE"; then
			echo -e "${BLUE}⏩ skipped (no go.mod)${RESET}"
			SKIPPED_NOGO=$((SKIPPED_NOGO + 1))
			continue
		fi

		# Check if repo is recently confirmed in tracking issue (within 24h)
		if is_recently_confirmed "$repo"; then
			echo -e "${RED}⚠️  USES DEPRECATED io/ioutil ${BLUE}(from tracking issue - skipped API)${RESET}"
			echo "$repo" >>"$temp_results"
			DEPRECATED_REPOS+=("$repo")
			SKIPPED_TRACKING_ISSUE=$((SKIPPED_TRACKING_ISSUE + 1))

			# Update cache
			update_cache_result "$repo" "true" "true"

			# Fetch last commit date from default branch for tracking issue
			last_commit=$(gh api "repos/${repo}/commits/${branch}" --jq '.commit.committer.date' 2>/dev/null || echo "unknown")

			# Check for open PRs related to ioutil migration
			pr_status=$(check_ioutil_pr "$repo")

			# Store for org-specific data: org|repo|branch|last_commit|pr_status
			echo "$ORG_NAME|$repo|$branch|$last_commit|$pr_status" >>"$ORG_DATA_FILE"
			continue
		fi

		# Check results cache first
		if [ "$CACHE_VALID" = true ]; then
			cached_result=$(get_cached_result "$repo")
			if [ "$cached_result" != "unknown" ]; then
				# Parse cached result
				cached_uses_ioutil=$(echo "$cached_result" | jq -r '.uses_ioutil')
				cached_api_success=$(echo "$cached_result" | jq -r '.api_success')

				if [ "$cached_api_success" = "true" ]; then
					if [ "$cached_uses_ioutil" = "true" ]; then
						echo -e "${RED}⚠️  USES DEPRECATED io/ioutil ${BLUE}(cached)${RESET}"
						echo "$repo" >>"$temp_results"
						DEPRECATED_REPOS+=("$repo")

						# Fetch last commit date from default branch for tracking issue
						last_commit=$(gh api "repos/${repo}/commits/${branch}" --jq '.commit.committer.date' 2>/dev/null || echo "unknown")

						# Check for open PRs related to ioutil migration
						pr_status=$(check_ioutil_pr "$repo")

						# Store for org-specific data: org|repo|branch|last_commit|pr_status
						echo "$ORG_NAME|$repo|$branch|$last_commit|$pr_status" >>"$ORG_DATA_FILE"
					else
						echo -e "${GREEN}✓ No deprecated usage ${BLUE}(cached)${RESET}"
					fi
					continue
				fi
				# If cached_api_success is false, fall through to re-check
			fi
		fi

		# Check for io/ioutil usage
		check_ioutil_usage "$repo" "$branch"
		result=$?

		if [ $result -eq 0 ]; then
			echo -e "${RED}⚠️  USES DEPRECATED io/ioutil${RESET}"
			echo "$repo" >>"$temp_results"
			DEPRECATED_REPOS+=("$repo")

			# Update cache
			update_cache_result "$repo" "true" "true"

			# Fetch last commit date from default branch for tracking issue
			last_commit=$(gh api "repos/${repo}/commits/${branch}" --jq '.commit.committer.date' 2>/dev/null || echo "unknown")

			# Check for open PRs related to ioutil migration
			pr_status=$(check_ioutil_pr "$repo")

			# Store for org-specific data: org|repo|branch|last_commit|pr_status
			echo "$ORG_NAME|$repo|$branch|$last_commit|$pr_status" >>"$ORG_DATA_FILE"
		elif [ $result -eq 1 ]; then
			echo -e "${GREEN}✓ No deprecated usage${RESET}"
			# Update cache
			update_cache_result "$repo" "false" "true"
		elif [ $result -eq 3 ]; then
			echo -e "${YELLOW}no go.mod (cached)${RESET}"
			echo "$repo" >>"$NOGO_TEMP"
			SKIPPED_NOGO=$((SKIPPED_NOGO + 1))
			# Update cache
			update_cache_result "$repo" "null" "true" "no_gomod"
		else
			echo -e "${YELLOW}? Unable to check (API rate limit or access issue)${RESET}"
			# Update cache with failure
			update_cache_result "$repo" "null" "false" "rate_limit"
			# Sleep briefly to respect rate limits
			sleep 6
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
	echo -e "   ${RED}${ORG_FOUND}${RESET} repositories using deprecated io/ioutil"
	echo -e "${BLUE}─────────────────────────────────────────────────────${RESET}"
	echo
done

# Update no-Go cache
if [ -f "$NOGO_TEMP" ] && [ -s "$NOGO_TEMP" ]; then
	cat "$NOGO_TEMP" >>"$NOGO_CACHE"
	sort -u "$NOGO_CACHE" -o "$NOGO_CACHE"
	NEW_NOGO=$(wc -l <"$NOGO_TEMP" | tr -d ' ')
	echo -e "${BLUE}💾 Updated no-Go cache with ${NEW_NOGO} new entries${RESET}"
	echo
fi
rm -f "$NOGO_TEMP"

# Sort and deduplicate abandoned cache
if [ -f "$ABANDONED_CACHE" ] && [ -s "$ABANDONED_CACHE" ]; then
	sort -u "$ABANDONED_CACHE" -o "$ABANDONED_CACHE"
fi

# Final summary
echo -e "${BOLD}${BLUE}📈 FINAL RESULTS:${RESET}"
echo -e "${BOLD}   Total repositories scanned:${RESET} ${TOTAL_REPOS}"
echo -e "${BOLD}   Repositories skipped (forks):${RESET} ${BLUE}${SKIPPED_FORKS}${RESET}"
echo -e "${BOLD}   Repositories skipped (abandoned):${RESET} ${BLUE}${SKIPPED_ABANDONED}${RESET}"
echo -e "${BOLD}   Repositories skipped (non-Go):${RESET} ${BLUE}${SKIPPED_NOGO}${RESET}"
echo -e "${BOLD}   API calls saved (tracking issue):${RESET} ${GREEN}${SKIPPED_TRACKING_ISSUE}${RESET}"
echo -e "${BOLD}   Repositories with deprecated io/ioutil:${RESET} ${RED}${FOUND_COUNT}${RESET}"

# Calculate percentage safely (avoid division by zero)
ACTUAL_SCANNED=$((TOTAL_REPOS - SKIPPED_FORKS - SKIPPED_ABANDONED - SKIPPED_NOGO))
if [ $ACTUAL_SCANNED -gt 0 ]; then
	PERCENTAGE=$(awk "BEGIN { printf \"%.1f%%\", ($FOUND_COUNT/$ACTUAL_SCANNED)*100 }")
else
	PERCENTAGE="N/A (no repositories scanned)"
fi
echo -e "${BOLD}   Usage percentage:${RESET} ${PERCENTAGE}"
echo

# Display table of repositories using deprecated io/ioutil
if [ ${#DEPRECATED_REPOS[@]} -gt 0 ]; then
	echo -e "${RED}${BOLD}⚠️  REPOSITORIES USING DEPRECATED IO/IOUTIL:${RESET}"
	echo -e "${RED}═══════════════════════════════════════════════════════════${RESET}"
	echo
	printf "${BOLD}%-60s${RESET} ${BOLD}%s${RESET}\n" "Repository" "URL"
	printf "%s\n" "─────────────────────────────────────────────────────────────────────────────────────────────"

	for repo in "${DEPRECATED_REPOS[@]}"; do
		printf "%-60s https://github.com/%s\n" "$repo" "$repo"
	done

	echo
	echo -e "${YELLOW}${BOLD}💡 RECOMMENDATION:${RESET}"
	echo -e "${YELLOW}   Migrate from io/ioutil to io and os packages${RESET}"
	echo -e "${YELLOW}   Reference: https://go.dev/doc/go1.16${RESET}"
	echo

	# Generate Markdown report
	echo "📝 Generating markdown report: $OUTPUT_MD"
	{
		echo "# Deprecated io/ioutil Usage Report"
		echo ""
		echo "**Generated:** $(date '+%Y-%m-%d %H:%M:%S %Z')"
		echo ""
		echo "## Summary"
		echo ""
		echo "- **Total repositories scanned:** ${TOTAL_REPOS}"
		echo "- **Repositories skipped (forks):** ${SKIPPED_FORKS}"
		echo "- **Repositories skipped (abandoned - no commits in 6 months):** ${SKIPPED_ABANDONED}"
		echo "- **Repositories skipped (non-Go):** ${SKIPPED_NOGO}"
		echo "- **Repositories actually checked:** ${ACTUAL_SCANNED}"
		echo "- **Repositories using deprecated io/ioutil:** ${FOUND_COUNT}"
		echo "- **Usage percentage:** ${PERCENTAGE}"
		echo ""
		echo "## ⚠️  Important Notice"
		echo ""
		echo "The \`io/ioutil\` package was **deprecated in Go 1.16 (February 2021)**."
		echo ""
		echo "**Recommended Action:** Migrate to the \`io\` and \`os\` packages"
		echo ""
		echo "**Reference:** [Go 1.16 Release Notes](https://go.dev/doc/go1.16)"
		echo ""
		echo "## Repositories Using Deprecated io/ioutil"
		echo ""
		echo "| # | Repository | GitHub URL |"
		echo "|---|------------|------------|"

		counter=1
		for repo in "${DEPRECATED_REPOS[@]}"; do
			echo "| $counter | \`$repo\` | [View on GitHub](https://github.com/$repo) |"
			counter=$((counter + 1))
		done

		echo ""
		echo "---"
		echo ""
		echo "## Migration Guide"
		echo ""
		echo "### io/ioutil Deprecation - Package Replacements"
		echo ""
		echo "The following table shows the old \`io/ioutil\` functions and their new locations:"
		echo ""
		echo "| Deprecated (io/ioutil) | Replacement | Package |"
		echo "|------------------------|-------------|---------|"
		echo "| \`ioutil.Discard\` | \`io.Discard\` | io |"
		echo "| \`ioutil.NopCloser\` | \`io.NopCloser\` | io |"
		echo "| \`ioutil.ReadAll\` | \`io.ReadAll\` | io |"
		echo "| \`ioutil.ReadDir\` | \`os.ReadDir\` | os |"
		echo "| \`ioutil.ReadFile\` | \`os.ReadFile\` | os |"
		echo "| \`ioutil.TempDir\` | \`os.MkdirTemp\` | os |"
		echo "| \`ioutil.TempFile\` | \`os.CreateTemp\` | os |"
		echo "| \`ioutil.WriteFile\` | \`os.WriteFile\` | os |"
		echo ""
		echo "### Migration Steps"
		echo ""
		echo "1. **Update import statements:**"
		echo "   \`\`\`go"
		echo "   // Remove this:"
		echo "   import \"io/ioutil\""
		echo "   "
		echo "   // Add these as needed:"
		echo "   import \"io\""
		echo "   import \"os\""
		echo "   \`\`\`"
		echo ""
		echo "2. **Replace function calls:**"
		echo "   \`\`\`go"
		echo "   // Example 1: ReadFile"
		echo "   data, err := ioutil.ReadFile(\"file.txt\")  // Old"
		echo "   data, err := os.ReadFile(\"file.txt\")     // New"
		echo "   "
		echo "   // Example 2: WriteFile"
		echo "   err := ioutil.WriteFile(\"file.txt\", data, 0644)  // Old"
		echo "   err := os.WriteFile(\"file.txt\", data, 0644)     // New"
		echo "   "
		echo "   // Example 3: ReadAll"
		echo "   data, err := ioutil.ReadAll(reader)  // Old"
		echo "   data, err := io.ReadAll(reader)     // New"
		echo "   \`\`\`"
		echo ""
		echo "3. **Run tests to verify:**"
		echo "   \`\`\`bash"
		echo "   go test ./..."
		echo "   \`\`\`"
		echo ""
		echo "4. **Update go.mod to use Go 1.16+:**"
		echo "   \`\`\`"
		echo "   go 1.16"
		echo "   \`\`\`"
		echo ""
	} >"$OUTPUT_MD"

	echo -e "${GREEN}✅ Markdown report saved to: $OUTPUT_MD${RESET}"
	echo
else
	echo -e "${GREEN}${BOLD}✅ Great! No repositories found using deprecated io/ioutil${RESET}"
	echo

	# Generate empty report
	{
		echo "# Deprecated io/ioutil Usage Report"
		echo ""
		echo "**Generated:** $(date '+%Y-%m-%d %H:%M:%S %Z')"
		echo ""
		echo "## Summary"
		echo ""
		echo "- **Total repositories scanned:** ${TOTAL_REPOS}"
		echo "- **Repositories skipped (forks):** ${SKIPPED_FORKS}"
		echo "- **Repositories skipped (abandoned - no commits in 6 months):** ${SKIPPED_ABANDONED}"
		echo "- **Repositories skipped (non-Go):** ${SKIPPED_NOGO}"
		echo "- **Repositories actually checked:** ${ACTUAL_SCANNED}"
		echo "- **Repositories using deprecated io/ioutil:** ${FOUND_COUNT}"
		echo ""
		echo "## ✅ Result"
		echo ""
		echo "**Great!** No repositories found using the deprecated \`io/ioutil\` package."
		echo ""
	} >"$OUTPUT_MD"

	echo "📝 Empty report saved to: $OUTPUT_MD"
	echo
fi

# Update tracking issue in telco-bot repo
echo -e "${BLUE}${BOLD}📋 Updating Central Tracking Issue${RESET}"
echo -e "${BLUE}─────────────────────────────────────────────────────${RESET}"
echo -e "${BLUE}   Building issue body with ${FOUND_COUNT} repositories using deprecated io/ioutil...${RESET}"

# Build the issue body
ISSUE_BODY="# Deprecated io/ioutil Usage Report

**Last Updated:** $(date -u '+%Y-%m-%d %H:%M:%S UTC')  
**Replacement:** Use \`io\` and \`os\` packages  
**Reference:** [Go 1.16 Release Notes](https://go.dev/doc/go1.16)

## Summary

- **Total Repositories Scanned:** ${TOTAL_REPOS}
- **Repositories Skipped (forks):** ${SKIPPED_FORKS}
- **Repositories Skipped (abandoned - no commits in 6 months):** ${SKIPPED_ABANDONED}
- **Repositories Skipped (non-Go):** ${SKIPPED_NOGO}
- **Repositories Actually Checked:** ${ACTUAL_SCANNED}
- **Repositories Using Deprecated io/ioutil:** ${FOUND_COUNT}
- **Usage Percentage:** ${PERCENTAGE}

---

"

if [ $FOUND_COUNT -gt 0 ]; then
	# Group by organization and create tables
	for ORG_NAME in "${ORGS[@]}"; do
		# Check if this org has any repos using deprecated io/ioutil
		ORG_REPOS=$(grep "^${ORG_NAME}|" "$ORG_DATA_FILE" 2>/dev/null || true)

		if [ -n "$ORG_REPOS" ]; then
			ORG_COUNT=$(echo "$ORG_REPOS" | wc -l | tr -d ' ')

			ISSUE_BODY+="## [${ORG_NAME}](https://github.com/${ORG_NAME})

**Repositories Using Deprecated io/ioutil:** ${ORG_COUNT}

| Repository | Branch | Last Updated | PR Status | Needs Rebase? |
|------------|--------|--------------|-----------|---------------|
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
				# Format PR status with emoji indicators and extract rebase status
				if [ "$pr_status" = "none" ] || [ -z "$pr_status" ]; then
					pr_display="—"
					rebase_display="—"
				else
					# Parse pr_status format: #123;https://github.com/org/repo/pull/123;status;needs_rebase
					pr_number=$(echo "$pr_status" | cut -d';' -f1)
					pr_url=$(echo "$pr_status" | cut -d';' -f2)
					pr_state=$(echo "$pr_status" | cut -d';' -f3)
					needs_rebase=$(echo "$pr_status" | cut -d';' -f4)

					# Add emoji based on PR state
					case "$pr_state" in
					"merged")
						pr_emoji="✅"
						;;
					"open")
						pr_emoji="🔄"
						;;
					"closed")
						pr_emoji="❌"
						;;
					*)
						pr_emoji=""
						;;
					esac

					pr_display="${pr_emoji} [${pr_number}](${pr_url})"

					# Format rebase status
					case "$needs_rebase" in
					"yes")
						rebase_display="⚠️  Yes"
						;;
					"no")
						rebase_display="✅ No"
						;;
					"unknown")
						rebase_display="❓ Unknown"
						;;
					*)
						rebase_display="—"
						;;
					esac
				fi
				echo "| [\`${repo_display}\`](https://github.com/${repo}) | \`${branch}\` | ${last_commit_display} | ${pr_display} | ${rebase_display} |"
			done >>"${ORG_DATA_FILE}.table"

			ISSUE_BODY+="$(cat "${ORG_DATA_FILE}.table")

"
			rm -f "${ORG_DATA_FILE}.table"
		fi
	done

	ISSUE_BODY+="---

## What to Do

The \`io/ioutil\` package was **deprecated in Go 1.16 (February 2021)** and its functionality has been moved to the \`io\` and \`os\` packages.

### Migration Guide

The following table shows the replacements for deprecated \`io/ioutil\` functions:

| Deprecated (io/ioutil) | Replacement | Package |
|------------------------|-------------|---------|
| \`ioutil.Discard\` | \`io.Discard\` | io |
| \`ioutil.NopCloser\` | \`io.NopCloser\` | io |
| \`ioutil.ReadAll\` | \`io.ReadAll\` | io |
| \`ioutil.ReadDir\` | \`os.ReadDir\` | os |
| \`ioutil.ReadFile\` | \`os.ReadFile\` | os |
| \`ioutil.TempDir\` | \`os.MkdirTemp\` | os |
| \`ioutil.TempFile\` | \`os.CreateTemp\` | os |
| \`ioutil.WriteFile\` | \`os.WriteFile\` | os |

### Migration Steps

1. **Update import statements:**
   \`\`\`go
   // Remove this:
   import \"io/ioutil\"
   
   // Add these as needed:
   import \"io\"
   import \"os\"
   \`\`\`

2. **Replace function calls:**
   \`\`\`go
   // Example: ReadFile
   data, err := ioutil.ReadFile(\"file.txt\")  // Old
   data, err := os.ReadFile(\"file.txt\")     // New
   \`\`\`

3. **Run tests:**
   \`\`\`bash
   go test ./...
   \`\`\`

### Resources

- [Go 1.16 Release Notes](https://go.dev/doc/go1.16)
- [io package documentation](https://pkg.go.dev/io)
- [os package documentation](https://pkg.go.dev/os)

"
else
	ISSUE_BODY+="## ✅ All Clear!

All scanned Go repositories have been updated and are no longer using the deprecated \`io/ioutil\` package. Great work! 🎉

"
fi

ISSUE_BODY+="---

*This issue is automatically updated by the [ioutil-deprecation-checker.sh](https://github.com/${TRACKING_REPO}/blob/main/scripts/ioutil-deprecation-checker.sh) script.*"

# Check if tracking issue exists
echo -e "${BLUE}   Issue body built successfully${RESET}"
echo -ne "   Checking for existing tracking issue... "
EXISTING_ISSUE=$(gh issue list --repo "$TRACKING_REPO" --search "in:title \"${TRACKING_ISSUE_TITLE}\"" --state all --json number,title,state --jq ".[] | select(.title == \"${TRACKING_ISSUE_TITLE}\") | .number" | head -1)

if [ -n "$EXISTING_ISSUE" ]; then
	echo -e "${GREEN}found (#${EXISTING_ISSUE})${RESET}"
	echo -ne "   Updating issue #${EXISTING_ISSUE}... "

	# Check if issue is closed and reopen it if there are repos using deprecated io/ioutil
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

# Update cache timestamp
echo -e "${BLUE}💾 Updating results cache timestamp...${RESET}"
update_cache_timestamp

# Cleanup temporary files
rm -f "$ORG_DATA_FILE" "$TRACKING_ISSUE_CACHE"

echo -e "${GREEN}${BOLD}✅ Scan completed successfully!${RESET}"
