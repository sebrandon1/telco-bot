#!/bin/bash

#===============================================================================
# UPDATE SHARED CACHES
#===============================================================================
#
# DESCRIPTION:
#   This script updates the shared cache files used by all lookup scripts.
#   It scans GitHub organizations to identify:
#   - Fork repositories
#   - Abandoned repositories (no commits in specified days)
#   - Repositories without go.mod files
#
#   If any caches have changed, it can optionally create a pull request
#   with the updates.
#
# PREREQUISITES:
#   1. GitHub CLI (gh) must be installed and authenticated
#   2. jq must be installed for JSON processing
#   3. Internet connection to fetch repository data
#
# USAGE:
#   ./update-caches.sh [OPTIONS]
#
# OPTIONS:
#   --create-pr       Create a pull request if caches have changed
#   --days NUMBER     Days of inactivity for abandoned repos (default: 180)
#   --dry-run         Show what would be done without making changes
#   --help            Show this help message
#
# OUTPUT:
#   - Updates scripts/caches/forks.txt
#   - Updates scripts/caches/abandoned.txt
#   - Updates scripts/caches/no-gomod.txt
#   - Optionally creates a PR with changes
#
#===============================================================================

set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CACHE_DIR="$SCRIPT_DIR/caches"

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
CREATE_PR=false
INACTIVITY_DAYS=180
DRY_RUN=false

while [[ $# -gt 0 ]]; do
	case $1 in
	--create-pr)
		CREATE_PR=true
		shift
		;;
	--days)
		INACTIVITY_DAYS="$2"
		shift 2
		;;
	--dry-run)
		DRY_RUN=true
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

# Configuration
ORGS=("redhat-best-practices-for-k8s" "openshift-kni" "redhat-openshift-ecosystem" "redhatci" "openshift")
LIMIT=1000

# Ensure cache directory exists
mkdir -p "$CACHE_DIR"

# Temporary files
TEMP_FORKS=$(mktemp)
TEMP_ABANDONED=$(mktemp)
TEMP_NOGOMOD=$(mktemp)

# Cleanup on exit
cleanup() {
	rm -f "$TEMP_FORKS" "$TEMP_ABANDONED" "$TEMP_NOGOMOD"
}
trap cleanup EXIT

# Calculate cutoff date
CUTOFF_DATE=$(date -u -v-${INACTIVITY_DAYS}d "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "${INACTIVITY_DAYS} days ago" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")

if [ -z "$CUTOFF_DATE" ]; then
	echo -e "${RED}❌ ERROR: Unable to calculate cutoff date${RESET}" >&2
	exit 1
fi

echo -e "${BLUE}${BOLD}🔄 UPDATING SHARED CACHES${RESET}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${RESET}"
echo -e "${BLUE}📅 Abandoned cutoff: ${CUTOFF_DATE:0:10} (${INACTIVITY_DAYS} days)${RESET}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${RESET}"
echo

TOTAL_REPOS=0
FORK_COUNT=0
ABANDONED_COUNT=0
NOGOMOD_COUNT=0

# Scan each organization
for ORG_NAME in "${ORGS[@]}"; do
	echo -e "${YELLOW}${BOLD}👉 Organization: ${ORG_NAME}${RESET}"

	# Get all repos with fork status and default branch
	echo -e "${BLUE}   Fetching repository list...${RESET}"
	REPOS=$(gh repo list "$ORG_NAME" --limit "$LIMIT" --json nameWithOwner,isFork,isArchived,defaultBranchRef,parent -q '.[] | select(.isArchived == false) | "\(.nameWithOwner)|\(.isFork)|\(.defaultBranchRef.name // "main")|\(.parent.nameWithOwner // "")"')

	if [[ $? -ne 0 ]]; then
		echo -e "${RED}   ✗ Failed to fetch repositories from ${ORG_NAME}${RESET}"
		continue
	fi

	REPO_COUNT=$(echo "$REPOS" | grep -v '^$' | wc -l | tr -d ' ')
	TOTAL_REPOS=$((TOTAL_REPOS + REPO_COUNT))
	echo -e "${BLUE}   Found ${REPO_COUNT} non-archived repositories${RESET}"

	ORG_FORKS=0
	ORG_ABANDONED=0
	ORG_NOGOMOD=0

	while IFS='|' read -r repo is_fork branch parent; do
		# Skip empty lines
		[[ -z "$repo" ]] && continue

		echo -ne "   📂 ${repo}... "

		# Check if repo is a fork
		if [ "$is_fork" = "true" ]; then
			if [ -n "$parent" ]; then
				echo -e "${YELLOW}🍴 fork of ${parent}${RESET}"
			else
				echo -e "${YELLOW}🍴 fork${RESET}"
			fi
			echo "$repo" >>"$TEMP_FORKS"
			ORG_FORKS=$((ORG_FORKS + 1))
			FORK_COUNT=$((FORK_COUNT + 1))
			continue
		fi

		# Check for go.mod
		raw_url="https://raw.githubusercontent.com/$repo/$branch/go.mod"
		if ! curl -s -f -I "$raw_url" >/dev/null 2>&1; then
			echo -e "${BLUE}📭 no go.mod${RESET}"
			echo "$repo" >>"$TEMP_NOGOMOD"
			ORG_NOGOMOD=$((ORG_NOGOMOD + 1))
			NOGOMOD_COUNT=$((NOGOMOD_COUNT + 1))
			continue
		fi

		# Check if repo is abandoned (no commits in last N days)
		last_commit=$(gh api "repos/${repo}/commits/${branch}" --jq '.commit.committer.date' 2>/dev/null || echo "")

		if [[ -z "$last_commit" ]]; then
			echo -e "${GREEN}✓ active (could not fetch last commit)${RESET}"
			continue
		fi

		if [ "$last_commit" \< "$CUTOFF_DATE" ]; then
			echo -e "${RED}💤 abandoned (last: ${last_commit:0:10})${RESET}"
			echo "$repo" >>"$TEMP_ABANDONED"
			ORG_ABANDONED=$((ORG_ABANDONED + 1))
			ABANDONED_COUNT=$((ABANDONED_COUNT + 1))
		else
			echo -e "${GREEN}✓ active (last: ${last_commit:0:10})${RESET}"
		fi
	done <<<"$REPOS"

	echo
	echo -e "${YELLOW}${BOLD}📊 Summary for ${ORG_NAME}:${RESET}"
	echo -e "   ${BLUE}Repositories checked:${RESET} ${REPO_COUNT}"
	echo -e "   ${YELLOW}Forks:${RESET} ${ORG_FORKS}"
	echo -e "   ${BLUE}No go.mod:${RESET} ${ORG_NOGOMOD}"
	echo -e "   ${RED}Abandoned:${RESET} ${ORG_ABANDONED}"
	echo -e "${BLUE}─────────────────────────────────────────────────────${RESET}"
	echo
done

# Final summary
echo -e "${BOLD}${BLUE}📈 FINAL RESULTS:${RESET}"
echo -e "${BOLD}   Total repositories scanned:${RESET} ${TOTAL_REPOS}"
echo -e "${BOLD}   Fork repositories:${RESET} ${YELLOW}${FORK_COUNT}${RESET}"
echo -e "${BOLD}   Repositories without go.mod:${RESET} ${BLUE}${NOGOMOD_COUNT}${RESET}"
echo -e "${BOLD}   Abandoned repositories:${RESET} ${RED}${ABANDONED_COUNT}${RESET}"
echo

# Sort and prepare new caches
sort -u "$TEMP_FORKS" >"${TEMP_FORKS}.sorted"
sort -u "$TEMP_ABANDONED" >"${TEMP_ABANDONED}.sorted"
sort -u "$TEMP_NOGOMOD" >"${TEMP_NOGOMOD}.sorted"

# Check for changes
FORKS_CHANGED=false
ABANDONED_CHANGED=false
NOGOMOD_CHANGED=false

if [ -f "$CACHE_DIR/forks.txt" ]; then
	if ! diff -q "${TEMP_FORKS}.sorted" "$CACHE_DIR/forks.txt" >/dev/null 2>&1; then
		FORKS_CHANGED=true
	fi
else
	FORKS_CHANGED=true
fi

if [ -f "$CACHE_DIR/abandoned.txt" ]; then
	if ! diff -q "${TEMP_ABANDONED}.sorted" "$CACHE_DIR/abandoned.txt" >/dev/null 2>&1; then
		ABANDONED_CHANGED=true
	fi
else
	ABANDONED_CHANGED=true
fi

if [ -f "$CACHE_DIR/no-gomod.txt" ]; then
	if ! diff -q "${TEMP_NOGOMOD}.sorted" "$CACHE_DIR/no-gomod.txt" >/dev/null 2>&1; then
		NOGOMOD_CHANGED=true
	fi
else
	NOGOMOD_CHANGED=true
fi

# Report changes
echo -e "${BLUE}${BOLD}🔍 CACHE CHANGES:${RESET}"

if [ "$FORKS_CHANGED" = true ]; then
	if [ -f "$CACHE_DIR/forks.txt" ]; then
		OLD_COUNT=$(wc -l <"$CACHE_DIR/forks.txt" | tr -d ' ')
		NEW_COUNT=$(wc -l <"${TEMP_FORKS}.sorted" | tr -d ' ')
		echo -e "   ${YELLOW}forks.txt:${RESET} changed (${OLD_COUNT} → ${NEW_COUNT})"
	else
		NEW_COUNT=$(wc -l <"${TEMP_FORKS}.sorted" | tr -d ' ')
		echo -e "   ${YELLOW}forks.txt:${RESET} new file (${NEW_COUNT} entries)"
	fi
else
	echo -e "   ${GREEN}forks.txt:${RESET} no changes"
fi

if [ "$ABANDONED_CHANGED" = true ]; then
	if [ -f "$CACHE_DIR/abandoned.txt" ]; then
		OLD_COUNT=$(wc -l <"$CACHE_DIR/abandoned.txt" | tr -d ' ')
		NEW_COUNT=$(wc -l <"${TEMP_ABANDONED}.sorted" | tr -d ' ')
		echo -e "   ${YELLOW}abandoned.txt:${RESET} changed (${OLD_COUNT} → ${NEW_COUNT})"
	else
		NEW_COUNT=$(wc -l <"${TEMP_ABANDONED}.sorted" | tr -d ' ')
		echo -e "   ${YELLOW}abandoned.txt:${RESET} new file (${NEW_COUNT} entries)"
	fi
else
	echo -e "   ${GREEN}abandoned.txt:${RESET} no changes"
fi

if [ "$NOGOMOD_CHANGED" = true ]; then
	if [ -f "$CACHE_DIR/no-gomod.txt" ]; then
		OLD_COUNT=$(wc -l <"$CACHE_DIR/no-gomod.txt" | tr -d ' ')
		NEW_COUNT=$(wc -l <"${TEMP_NOGOMOD}.sorted" | tr -d ' ')
		echo -e "   ${YELLOW}no-gomod.txt:${RESET} changed (${OLD_COUNT} → ${NEW_COUNT})"
	else
		NEW_COUNT=$(wc -l <"${TEMP_NOGOMOD}.sorted" | tr -d ' ')
		echo -e "   ${YELLOW}no-gomod.txt:${RESET} new file (${NEW_COUNT} entries)"
	fi
else
	echo -e "   ${GREEN}no-gomod.txt:${RESET} no changes"
fi

echo

# Check if any changes
ANY_CHANGES=false
if [ "$FORKS_CHANGED" = true ] || [ "$ABANDONED_CHANGED" = true ] || [ "$NOGOMOD_CHANGED" = true ]; then
	ANY_CHANGES=true
fi

if [ "$ANY_CHANGES" = false ]; then
	echo -e "${GREEN}${BOLD}✅ All caches are up to date!${RESET}"
	exit 0
fi

# Apply changes (unless dry run)
if [ "$DRY_RUN" = true ]; then
	echo -e "${YELLOW}${BOLD}🔍 DRY RUN: Would update the following caches${RESET}"
	if [ "$FORKS_CHANGED" = true ]; then
		echo -e "   - forks.txt"
	fi
	if [ "$ABANDONED_CHANGED" = true ]; then
		echo -e "   - abandoned.txt"
	fi
	if [ "$NOGOMOD_CHANGED" = true ]; then
		echo -e "   - no-gomod.txt"
	fi
	exit 0
fi

# Update cache files
echo -e "${BLUE}${BOLD}💾 Updating cache files...${RESET}"

if [ "$FORKS_CHANGED" = true ]; then
	cp "${TEMP_FORKS}.sorted" "$CACHE_DIR/forks.txt"
	echo -e "   ${GREEN}✓ Updated forks.txt${RESET}"
fi

if [ "$ABANDONED_CHANGED" = true ]; then
	cp "${TEMP_ABANDONED}.sorted" "$CACHE_DIR/abandoned.txt"
	echo -e "   ${GREEN}✓ Updated abandoned.txt${RESET}"
fi

if [ "$NOGOMOD_CHANGED" = true ]; then
	cp "${TEMP_NOGOMOD}.sorted" "$CACHE_DIR/no-gomod.txt"
	echo -e "   ${GREEN}✓ Updated no-gomod.txt${RESET}"
fi

echo

# Create PR if requested
if [ "$CREATE_PR" = true ]; then
	echo -e "${BLUE}${BOLD}📝 Creating Pull Request...${RESET}"

	cd "$REPO_ROOT"

	# Check if there are uncommitted changes to cache files
	if ! git diff --quiet -- scripts/caches/; then
		BRANCH_NAME="cache-update-$(date +%Y%m%d-%H%M%S)"
		DATE_DISPLAY=$(date '+%Y-%m-%d')

		echo -e "   Creating branch: ${BRANCH_NAME}"
		git checkout -b "$BRANCH_NAME"

		echo -e "   Staging cache files..."
		git add scripts/caches/

		echo -e "   Committing changes..."
		git commit -m "chore: update shared caches (${DATE_DISPLAY})

Automated cache update:
- forks.txt: ${FORK_COUNT} entries
- abandoned.txt: ${ABANDONED_COUNT} entries
- no-gomod.txt: ${NOGOMOD_COUNT} entries

Scanned ${TOTAL_REPOS} repositories across ${#ORGS[@]} organizations."

		echo -e "   Pushing branch..."
		git push origin "$BRANCH_NAME"

		echo -e "   Creating pull request..."
		PR_BODY="## Automated Cache Update

This PR updates the shared cache files used by lookup scripts.

### Changes
| Cache | Entries |
|-------|---------|
| forks.txt | ${FORK_COUNT} |
| abandoned.txt | ${ABANDONED_COUNT} |
| no-gomod.txt | ${NOGOMOD_COUNT} |

### Scan Details
- **Total repositories scanned:** ${TOTAL_REPOS}
- **Organizations:** ${ORGS[*]}
- **Abandoned threshold:** ${INACTIVITY_DAYS} days

---
*This PR was automatically created by the \`update-caches.sh\` script.*"

		PR_URL=$(gh pr create --title "chore: update shared caches (${DATE_DISPLAY})" --body "$PR_BODY" --base main)

		if [ $? -eq 0 ]; then
			echo -e "${GREEN}   ✓ Pull request created: ${PR_URL}${RESET}"
		else
			echo -e "${RED}   ✗ Failed to create pull request${RESET}"
		fi

		# Switch back to main
		git checkout main
	else
		echo -e "${YELLOW}   No uncommitted changes to cache files${RESET}"
	fi
fi

echo
echo -e "${GREEN}${BOLD}✅ Cache update completed successfully!${RESET}"
