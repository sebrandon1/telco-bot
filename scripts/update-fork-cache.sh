#!/bin/bash

#===============================================================================
# UPDATE FORK CACHE
#===============================================================================
#
# DESCRIPTION:
#   This script scans GitHub organizations to identify repositories that are
#   forks of upstream projects. It maintains a cache file for these fork
#   repositories and optionally closes any open Go version update issues on
#   them, since forks typically need to stay in sync with their upstream.
#
# PREREQUISITES:
#   1. GitHub CLI (gh) must be installed and authenticated
#   2. jq must be installed for JSON processing
#   3. Internet connection to fetch repository data
#
# USAGE:
#   ./update-fork-cache.sh [OPTIONS]
#
# OPTIONS:
#   --close-issues    Close open Go version issues on fork repos
#   --help            Show this help message
#
# OUTPUT:
#   - Updates .go-version-checker-forks.cache with fork repo list
#   - Optionally closes open issues on fork repositories
#   - Shows summary of findings
#
#===============================================================================

# Check for help flag first
for arg in "$@"; do
	if [ "$arg" = "--help" ] || [ "$arg" = "-h" ]; then
		awk '/^#=====/ { if (++count == 3) exit; next } count == 2 && /^#/ { sub(/^# ?/, ""); print }' "$0"
		exit 0
	fi
done

# Check if GitHub CLI is installed
if ! command -v gh &>/dev/null; then
	echo "❌ ERROR: GitHub CLI (gh) is not installed!" >&2
	echo "💡 Please install it first: https://cli.github.com/" >&2
	exit 1
fi

# Check if GitHub CLI is logged in
if ! gh auth status &>/dev/null; then
	echo "❌ ERROR: GitHub CLI is not logged in!" >&2
	echo "💡 Please run 'gh auth login' to authenticate first." >&2
	exit 1
fi

# Check if jq is installed
if ! command -v jq &>/dev/null; then
	echo "❌ ERROR: jq is not installed!" >&2
	echo "💡 Please install jq for JSON processing." >&2
	exit 1
fi

# Parse command line arguments
CLOSE_ISSUES=false

while [[ $# -gt 0 ]]; do
	case $1 in
	--close-issues)
		CLOSE_ISSUES=true
		shift
		;;
	*)
		echo "❌ ERROR: Unknown option: $1" >&2
		echo "Use --help or -h for usage information" >&2
		exit 1
		;;
	esac
done

# Terminal colors
GREEN="\033[0;32m"
RED="\033[0;31m"
BLUE="\033[0;34m"
YELLOW="\033[0;33m"
BOLD="\033[1m"
RESET="\033[0m"

# Get script directory for relative paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration
ORGS=("redhat-best-practices-for-k8s" "openshift-kni" "redhat-openshift-ecosystem" "redhatci" "openshift")
CACHE_DIR="$SCRIPT_DIR/caches"
CACHE_FILE="$CACHE_DIR/forks.txt"
LIMIT=1000

# Ensure cache directory exists
mkdir -p "$CACHE_DIR"

echo -e "${BLUE}${BOLD}🔍 FINDING FORK REPOSITORIES${RESET}"
echo -e "${BLUE}─────────────────────────────────────────────────────${RESET}"
echo

# Temporary files
FORK_REPOS=$(mktemp)
CLOSED_ISSUES=$(mktemp)

TOTAL_REPOS=0
FORK_COUNT=0
ISSUES_CLOSED=0

# Scan each organization
for ORG_NAME in "${ORGS[@]}"; do
	echo -e "${YELLOW}${BOLD}👉 Organization: ${ORG_NAME}${RESET}"

	# Get all repos with fork status
	echo -e "${BLUE}   Fetching repository list...${RESET}"
	REPOS=$(gh repo list "$ORG_NAME" --limit "$LIMIT" --json nameWithOwner,isFork,isArchived,parent -q '.[] | select(.isArchived == false) | "\(.nameWithOwner)|\(.isFork)|\(.parent.nameWithOwner // "")"')

	if [[ $? -ne 0 ]]; then
		echo -e "${RED}   ✗ Failed to fetch repositories from ${ORG_NAME}${RESET}"
		continue
	fi

	REPO_COUNT=$(echo "$REPOS" | wc -l | tr -d ' ')
	TOTAL_REPOS=$((TOTAL_REPOS + REPO_COUNT))
	echo -e "${BLUE}   Found ${REPO_COUNT} non-archived repositories${RESET}"
	echo

	ORG_FORKS=0

	while IFS='|' read -r repo is_fork parent; do
		# Skip empty lines
		[[ -z "$repo" ]] && continue

		if [ "$is_fork" = "true" ]; then
			if [ -n "$parent" ]; then
				echo -e "   🍴 ${repo} ${BLUE}(fork of ${parent})${RESET}"
			else
				echo -e "   🍴 ${repo} ${BLUE}(fork)${RESET}"
			fi

			echo "$repo" >>"$FORK_REPOS"
			ORG_FORKS=$((ORG_FORKS + 1))
			FORK_COUNT=$((FORK_COUNT + 1))

			# Close issues if requested
			if [ "$CLOSE_ISSUES" = true ]; then
				existing_issue=$(gh issue list --repo "$repo" --search "Update Go version" --state open --json number,title --jq ".[] | select(.title | test(\"Update Go version from\")) | .number" 2>/dev/null | head -1)
				if [ -n "$existing_issue" ]; then
					echo -ne "      Closing issue #${existing_issue}... "
					if gh issue close "$existing_issue" --repo "$repo" &>/dev/null; then
						echo -e "${GREEN}✓ Closed${RESET}"
						echo "$repo|$existing_issue" >>"$CLOSED_ISSUES"
						ISSUES_CLOSED=$((ISSUES_CLOSED + 1))
					else
						echo -e "${RED}✗ Failed${RESET}"
					fi
				fi
			fi
		fi
	done <<<"$REPOS"

	echo
	echo -e "${YELLOW}${BOLD}📊 Summary for ${ORG_NAME}:${RESET}"
	echo -e "   ${BLUE}Repositories checked:${RESET} ${REPO_COUNT}"
	echo -e "   ${YELLOW}Fork repositories:${RESET} ${ORG_FORKS}"
	echo -e "${BLUE}─────────────────────────────────────────────────────${RESET}"
	echo
done

# Final summary
echo -e "${BOLD}${BLUE}📈 FINAL RESULTS:${RESET}"
echo -e "${BOLD}   Total repositories scanned:${RESET} ${TOTAL_REPOS}"
echo -e "${BOLD}   Fork repositories found:${RESET} ${YELLOW}${FORK_COUNT}${RESET}"
if [ "$CLOSE_ISSUES" = true ]; then
	echo -e "${BOLD}   Issues closed:${RESET} ${GREEN}${ISSUES_CLOSED}${RESET}"
fi
echo

# Save to cache
if [ -f "$FORK_REPOS" ] && [ -s "$FORK_REPOS" ]; then
	sort -u "$FORK_REPOS" >"$CACHE_FILE"
	echo -e "${GREEN}${BOLD}✅ Cache updated: ${CACHE_FILE}${RESET}"
	echo -e "${BLUE}   ${FORK_COUNT} fork repositories cached${RESET}"

	if [ "$CLOSE_ISSUES" = true ] && [ -f "$CLOSED_ISSUES" ] && [ -s "$CLOSED_ISSUES" ]; then
		echo
		echo -e "${BLUE}${BOLD}📋 Issues Closed:${RESET}"
		while IFS='|' read -r repo issue_num; do
			echo -e "   ${GREEN}✓${RESET} ${repo} - Issue #${issue_num}"
		done <"$CLOSED_ISSUES"
	fi
else
	echo -e "${GREEN}${BOLD}✅ No fork repositories found${RESET}"
	# Create empty cache file
	touch "$CACHE_FILE"
fi

# Cleanup
rm -f "$FORK_REPOS" "$CLOSED_ISSUES"

echo
echo -e "${GREEN}${BOLD}✅ Scan completed successfully!${RESET}"
