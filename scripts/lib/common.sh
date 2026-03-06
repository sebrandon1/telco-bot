#!/bin/bash
#===============================================================================
# COMMON LIBRARY FOR TELCO-BOT SCANNER SCRIPTS
#===============================================================================
#
# Shared functions and constants used across all scanner/lookup scripts.
# Source this file at the top of each script:
#
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/lib/common.sh"
#
#===============================================================================

# Terminal colors
GREEN="\033[0;32m"
RED="\033[0;31m"
BLUE="\033[0;34m"
YELLOW="\033[0;33m"
BOLD="\033[1m"
RESET="\033[0m"

# Default organizations to scan
DEFAULT_ORGS=("redhat-best-practices-for-k8s" "openshift" "openshift-kni" "redhat-openshift-ecosystem" "redhatci" "openshift-eng" "crc-org")

# Default repo fetch limit per org
DEFAULT_LIMIT=1000

# Default inactivity threshold (in days)
DEFAULT_INACTIVITY_DAYS=180

# Tracking issue repo
TRACKING_REPO="redhat-best-practices-for-k8s/telco-bot"

#===============================================================================
# PREREQUISITE CHECKS
#===============================================================================

# Check that a required tool is installed.
# Usage: require_tool gh jq curl
require_tool() {
	for cmd in "$@"; do
		if ! command -v "$cmd" &>/dev/null; then
			echo -e "${RED}ERROR: ${cmd} is not installed!${RESET}" >&2
			case "$cmd" in
			gh)
				echo -e "${YELLOW}Install: https://cli.github.com/${RESET}" >&2
				echo -e "${YELLOW}  macOS: brew install gh${RESET}" >&2
				echo -e "${YELLOW}  Linux: https://github.com/cli/cli/blob/trunk/docs/install_linux.md${RESET}" >&2
				;;
			jq)
				echo -e "${YELLOW}Install: brew install jq (macOS) or apt-get install jq (Linux)${RESET}" >&2
				;;
			*)
				echo -e "${YELLOW}Please install ${cmd} before running this script.${RESET}" >&2
				;;
			esac
			exit 1
		fi
	done
}

# Check that GitHub CLI is authenticated.
check_gh_auth() {
	if ! gh auth status &>/dev/null; then
		echo -e "${RED}ERROR: GitHub CLI is not logged in!${RESET}" >&2
		echo -e "${YELLOW}Please run 'gh auth login' to authenticate first.${RESET}" >&2
		exit 1
	fi
}

#===============================================================================
# CACHE FUNCTIONS
#===============================================================================

# Set up shared cache paths. Call after SCRIPT_DIR is set.
# Sets: CACHE_DIR, FORK_CACHE, NOGOMOD_CACHE, ABANDONED_CACHE
init_cache_paths() {
	CACHE_DIR="${SCRIPT_DIR}/caches"
	FORK_CACHE="${CACHE_DIR}/forks.txt"
	NOGOMOD_CACHE="${CACHE_DIR}/no-gomod.txt"
	ABANDONED_CACHE="${CACHE_DIR}/abandoned.txt"
	mkdir -p "$CACHE_DIR"
	touch "$FORK_CACHE" "$NOGOMOD_CACHE" "$ABANDONED_CACHE"
}

# Load and display cache counts. Call after init_cache_paths.
load_shared_caches() {
	local cache count
	for cache in "$FORK_CACHE:fork" "$NOGOMOD_CACHE:no-go.mod" "$ABANDONED_CACHE:abandoned"; do
		local file="${cache%%:*}"
		local label="${cache##*:}"
		if [ -f "$file" ] && [ -s "$file" ]; then
			count=$(wc -l <"$file" | tr -d ' ')
			echo -e "${GREEN}Loaded ${count} ${label} repositories to skip${RESET}"
		fi
	done
}

# Check if a repo is in a cache file.
# Usage: is_in_cache "org/repo" "$FORK_CACHE"
is_in_cache() {
	local repo="$1"
	local cache_file="$2"
	grep -Fxq "$repo" "$cache_file" 2>/dev/null
}

# Sort and deduplicate a cache file in place.
dedup_cache() {
	local cache_file="$1"
	if [ -f "$cache_file" ] && [ -s "$cache_file" ]; then
		sort -u "$cache_file" -o "$cache_file"
	fi
}

# Merge a temp file into a cache file, dedup, and report.
# Usage: merge_cache "$TEMP_FILE" "$CACHE_FILE" "label"
merge_cache() {
	local temp_file="$1"
	local cache_file="$2"
	local label="$3"

	if [ -f "$temp_file" ] && [ -s "$temp_file" ]; then
		cat "$temp_file" >>"$cache_file"
		dedup_cache "$cache_file"
		local count
		count=$(wc -l <"$temp_file" | tr -d ' ')
		echo -e "${BLUE}Updated ${label} cache with ${count} new entries${RESET}"
	fi
}

#===============================================================================
# DATE HELPERS
#===============================================================================

# Calculate a cutoff date N days ago (cross-platform: macOS + Linux).
# Usage: CUTOFF_DATE=$(calculate_cutoff_date 180)
calculate_cutoff_date() {
	local days="${1:-$DEFAULT_INACTIVITY_DAYS}"
	local cutoff
	cutoff=$(date -u -v-${days}d "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null ||
		date -u -d "${days} days ago" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null ||
		echo "")
	if [ -z "$cutoff" ]; then
		echo -e "${RED}ERROR: Unable to calculate cutoff date${RESET}" >&2
		exit 1
	fi
	echo "$cutoff"
}

#===============================================================================
# REPO HELPERS
#===============================================================================

# Check if a repo is abandoned (no commits in last N days).
# Requires CUTOFF_DATE to be set.
# Usage: is_repo_abandoned "org/repo" "main"
is_repo_abandoned() {
	local repo="$1"
	local branch="$2"

	local last_commit
	last_commit=$(gh api "repos/${repo}/commits/${branch}" --jq '.commit.committer.date' 2>/dev/null)

	if [[ $? -ne 0 || -z "$last_commit" ]]; then
		return 1
	fi

	if [ "$last_commit" \< "$CUTOFF_DATE" ]; then
		return 0
	else
		return 1
	fi
}

# Normalize a repo reference to "owner/repo" format.
# Strips https://github.com/ prefix and whitespace.
# Usage: repo=$(normalize_repo "$input")
normalize_repo() {
	echo "$1" | sed -e 's|https://github.com/||' -e 's|github.com/||' -e 's|^[[:space:]]*||' -e 's|[[:space:]]*$||'
}

# Read a repo list file, skipping comments and blank lines, normalizing format.
# Outputs one "owner/repo" per line.
# Usage: read_repo_list "file.txt"
read_repo_list() {
	local file="$1"
	[ -f "$file" ] || return 0
	while IFS= read -r line || [ -n "$line" ]; do
		[[ -z "$line" || "$line" =~ ^[[:space:]]*(#|//) ]] && continue
		local repo
		repo=$(normalize_repo "$line")
		[[ -z "$repo" ]] && continue
		echo "$repo"
	done <"$file"
}

#===============================================================================
# HELP
#===============================================================================

# Display help text extracted from the script header (between 2nd and 3rd
# #===== markers). Call with "$0" as argument.
# Usage: show_help_from_header "$0"
show_help_from_header() {
	awk '/^#=====/ { if (++count == 3) exit; next } count == 2 && /^#/ { sub(/^# ?/, ""); print }' "$1"
}

#===============================================================================
# TRACKING ISSUES
#===============================================================================

# Find or create/update a tracking issue.
# Usage: upsert_tracking_issue "$TITLE" "$BODY" $FOUND_COUNT
upsert_tracking_issue() {
	local title="$1"
	local body="$2"
	local found_count="${3:-0}"

	echo -ne "   Checking for existing tracking issue... "
	local existing
	existing=$(gh issue list --repo "$TRACKING_REPO" --search "in:title \"${title}\"" --state all --json number,title,state --jq ".[] | select(.title == \"${title}\") | .number" | head -1)

	if [ -n "$existing" ]; then
		echo -e "${GREEN}found (#${existing})${RESET}"
		echo -ne "   Updating issue #${existing}... "

		local state
		state=$(gh issue view "$existing" --repo "$TRACKING_REPO" --json state --jq '.state')
		if [ "$state" = "CLOSED" ] && [ "$found_count" -gt 0 ]; then
			gh issue reopen "$existing" --repo "$TRACKING_REPO" &>/dev/null
		fi

		if gh issue edit "$existing" --repo "$TRACKING_REPO" --body "$body" &>/dev/null; then
			echo -e "${GREEN}Updated${RESET}"
			echo -e "   ${BLUE}View at: https://github.com/${TRACKING_REPO}/issues/${existing}${RESET}"
		else
			echo -e "${RED}Failed to update${RESET}"
		fi
	else
		echo -e "${YELLOW}not found${RESET}"
		echo -ne "   Creating new tracking issue... "

		local new_issue
		new_issue=$(gh issue create --repo "$TRACKING_REPO" --title "$title" --body "$body" 2>/dev/null)
		if [ $? -eq 0 ]; then
			local issue_number
			issue_number=$(echo "$new_issue" | grep -oE '[0-9]+$')
			echo -e "${GREEN}Created (#${issue_number})${RESET}"
			echo -e "   ${BLUE}View at: ${new_issue}${RESET}"
		else
			echo -e "${RED}Failed to create${RESET}"
		fi
	fi
}

#===============================================================================
# FORMAT HELPERS
#===============================================================================

# Format an ISO8601 date to YYYY-MM-DD (cross-platform).
# Usage: display=$(format_date "$iso_date")
format_date() {
	local iso_date="$1"
	if [ "$iso_date" = "unknown" ] || [ -z "$iso_date" ]; then
		echo "Unknown"
		return
	fi
	date -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso_date" "+%Y-%m-%d" 2>/dev/null ||
		date -d "$iso_date" "+%Y-%m-%d" 2>/dev/null ||
		echo "${iso_date:0:10}"
}
