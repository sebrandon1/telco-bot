#!/bin/bash

#===============================================================================
# GITHUB.COM/GOLANG/MOCK DEPRECATED USAGE SCANNER
#===============================================================================
#
# DESCRIPTION:
#   This script scans GitHub organizations for repositories that use the
#   deprecated github.com/golang/mock package. The golang/mock package was
#   archived in June 2023 and is no longer maintained. The official
#   recommendation is to use go.uber.org/mock as a maintained fork instead.
#
#   It identifies Go projects with direct dependencies (excluding indirect
#   dependencies) by examining go.mod files.
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
#   ./gomock-lookup.sh
#
# TRACKING ISSUE:
#   The script maintains a central tracking issue in the telco-bot repo
#   (https://github.com/redhat-best-practices-for-k8s/telco-bot/issues)
#   titled "Tracking Deprecated golang/mock Usage". This issue is automatically
#   created if it doesn't exist and updated with each run to show current status.
#
# CONFIGURATION:
#   You can customize which organizations to scan by editing the ORGS array
#   below (line ~85). Add or remove organization names as needed:
#
#   ORGS=("your-org" "another-org" "third-org")
#
#   You can also specify individual repositories in gomock-repo-list.txt
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
#   - Table format output showing all repositories using deprecated golang/mock
#   - PR status check for open pull requests related to gomock migration
#   - Markdown report file (gomock-usage-report.md)
#   - Automatic creation/update of central tracking issue in telco-bot repo
#
# LIMITATIONS:
#   - Limited to 1000 repositories per organization (configurable via LIMIT)
#   - Only detects direct dependencies, not transitive usage
#   - Requires public access to go.mod files or appropriate permissions
#
# REFERENCE:
#   - golang/mock archived repository: https://github.com/golang/mock
#   - Recommended replacement: go.uber.org/mock
#===============================================================================

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

# List of orgs to scan
ORGS=("redhat-best-practices-for-k8s" "openshift" "openshift-kni" "redhat-openshift-ecosystem" "redhatci")

LIMIT=1000
FOUND_COUNT=0
TOTAL_REPOS=0
SKIPPED_FORKS=0
SKIPPED_NOGOMOD=0
SKIPPED_ABANDONED=0

# Cache files
FORK_CACHE=".go-version-checker-forks.cache"
NOGOMOD_CACHE=".gomock-lookup-nogomod.cache"
ABANDONED_CACHE=".go-version-checker-abandoned.cache"
OUTPUT_MD="gomock-usage-report.md"

# Inactivity threshold (in days)
INACTIVITY_DAYS=180 # 6 months

# Create empty cache files if they don't exist
touch "$FORK_CACHE" "$NOGOMOD_CACHE" "$ABANDONED_CACHE"

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

# Helper function to check for open PRs related to gomock migration
check_gomock_pr() {
	local repo="$1"

	# List all open PRs and grep for keywords in the title
	# Note: --search flag does global search, not repo-specific, so we use grep instead
	local pr_search=$(gh pr list --repo "$repo" --state open --json number,title,url --limit 50 2>/dev/null)

	if [[ $? -ne 0 || -z "$pr_search" || "$pr_search" == "[]" ]]; then
		echo "none"
		return
	fi

	# Filter PRs that have gomock-related keywords in the title
	local pr_links=$(echo "$pr_search" | jq -r '.[] | select(.title | test("gomock|golang/mock|uber.org/mock|go.uber.org/mock"; "i")) | "#" + (.number|tostring) + ";" + .url' | head -1)

	if [[ -n "$pr_links" ]]; then
		echo "$pr_links"
	else
		echo "none"
	fi
}

# Terminal colors
GREEN="\033[0;32m"
RED="\033[0;31m"
BLUE="\033[0;34m"
YELLOW="\033[0;33m"
BOLD="\033[1m"
RESET="\033[0m"

# Tracking issue configuration
TRACKING_REPO="redhat-best-practices-for-k8s/telco-bot"
TRACKING_ISSUE_TITLE="Tracking Deprecated golang/mock Usage"

# Array to store repositories using deprecated golang/mock
declare -a DEPRECATED_REPOS

# Temporary file to store org-specific data for tracking issue (with last commit date and PR status)
ORG_DATA_FILE=$(mktemp)

echo -e "${BLUE}${BOLD}🔍 SCANNING REPOSITORIES FOR DEPRECATED GOLANG/MOCK USAGE${RESET}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${RESET}"
echo -e "${YELLOW}⚠️  Note: github.com/golang/mock was archived in June 2023${RESET}"
echo -e "${YELLOW}    Recommended replacement: go.uber.org/mock${RESET}"
echo -e "${BLUE}───────────────────────────────────────────────────────────${RESET}"
echo -e "${BLUE}📅 Skipping repos with no commits since: ${CUTOFF_DATE:0:10}${RESET}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${RESET}"
echo

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

	while read -r repo branch; do
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

		# Check for direct dependency on deprecated golang/mock (exclude // indirect)
		if echo "$go_mod" | grep -E '^[[:space:]]*github\.com/golang/mock' | grep -vq '// indirect'; then
			echo -e "${RED}⚠️  USES DEPRECATED golang/mock${RESET}"
			echo "$repo" >>"$temp_results"
			DEPRECATED_REPOS+=("$repo")

			# Fetch last commit date from default branch for tracking issue
			last_commit=$(gh api "repos/${repo}/commits/${branch}" --jq '.commit.committer.date' 2>/dev/null || echo "unknown")

			# Check for open PRs related to gomock migration
			pr_status=$(check_gomock_pr "$repo")

			# Store for org-specific data: org|repo|branch|last_commit|pr_status
			echo "$ORG_NAME|$repo|$branch|$last_commit|$pr_status" >>"$ORG_DATA_FILE"
		else
			echo -e "${GREEN}✓ No deprecated usage${RESET}"
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
	echo -e "   ${RED}${ORG_FOUND}${RESET} repositories using deprecated github.com/golang/mock"
	echo -e "${BLUE}─────────────────────────────────────────────────────${RESET}"
	echo
done

# Scan individual repositories from gomock-repo-list.txt if it exists
REPO_LIST_FILE="gomock-repo-list.txt"
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

		# Check if repo is in fork cache
		if is_in_cache "$repo" "$FORK_CACHE"; then
			echo -ne "   📂 ${repo}... "
			echo -e "${BLUE}⏩ skipped (fork)${RESET}"
			SKIPPED_FORKS=$((SKIPPED_FORKS + 1))
			continue
		fi

		# Get default branch for the repo
		echo -ne "   📂 ${repo}... "
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

		# Check for direct dependency on deprecated golang/mock (exclude // indirect)
		if echo "$go_mod" | grep -E '^[[:space:]]*github\.com/golang/mock' | grep -vq '// indirect'; then
			echo -e "${RED}⚠️  USES DEPRECATED golang/mock${RESET}"
			echo "$repo" >>"$temp_results"
			DEPRECATED_REPOS+=("$repo")

			# Fetch last commit date from default branch for tracking issue
			last_commit=$(gh api "repos/${repo}/commits/${branch}" --jq '.commit.committer.date' 2>/dev/null || echo "unknown")

			# Check for open PRs related to gomock migration
			pr_status=$(check_gomock_pr "$repo")

			# Store for org-specific data: org|repo|branch|last_commit|pr_status
			echo "Individual Repositories|$repo|$branch|$last_commit|$pr_status" >>"$ORG_DATA_FILE"
		else
			echo -e "${GREEN}✓ No deprecated usage${RESET}"
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
	echo -e "   ${RED}${INDIVIDUAL_FOUND}${RESET} repositories using deprecated github.com/golang/mock (out of ${INDIVIDUAL_COUNT} scanned)"
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
echo -e "${BOLD}   Repositories with deprecated golang/mock:${RESET} ${RED}${FOUND_COUNT}${RESET}"

# Calculate percentage safely (avoid division by zero)
ACTUAL_SCANNED=$((TOTAL_REPOS - SKIPPED_FORKS - SKIPPED_ABANDONED - SKIPPED_NOGOMOD))
if [ $ACTUAL_SCANNED -gt 0 ]; then
	PERCENTAGE=$(awk "BEGIN { printf \"%.1f%%\", ($FOUND_COUNT/$ACTUAL_SCANNED)*100 }")
else
	PERCENTAGE="N/A (no repositories scanned)"
fi
echo -e "${BOLD}   Usage percentage:${RESET} ${PERCENTAGE}"
echo

# Display table of repositories using deprecated golang/mock
if [ ${#DEPRECATED_REPOS[@]} -gt 0 ]; then
	echo -e "${RED}${BOLD}⚠️  REPOSITORIES USING DEPRECATED GOLANG/MOCK:${RESET}"
	echo -e "${RED}═══════════════════════════════════════════════════════════${RESET}"
	echo
	printf "${BOLD}%-60s${RESET} ${BOLD}%s${RESET}\n" "Repository" "URL"
	printf "%s\n" "─────────────────────────────────────────────────────────────────────────────────────────────"

	for repo in "${DEPRECATED_REPOS[@]}"; do
		printf "%-60s https://github.com/%s\n" "$repo" "$repo"
	done

	echo
	echo -e "${YELLOW}${BOLD}💡 RECOMMENDATION:${RESET}"
	echo -e "${YELLOW}   Migrate from github.com/golang/mock to go.uber.org/mock${RESET}"
	echo -e "${YELLOW}   Reference: https://github.com/golang/mock (archived)${RESET}"
	echo

	# Generate Markdown report
	echo "📝 Generating markdown report: $OUTPUT_MD"
	{
		echo "# Deprecated golang/mock Usage Report"
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
		echo "- **Repositories using deprecated golang/mock:** ${FOUND_COUNT}"
		echo "- **Usage percentage:** ${PERCENTAGE}"
		echo ""
		echo "## ⚠️  Important Notice"
		echo ""
		echo "The \`github.com/golang/mock\` package was **archived in June 2023** and is no longer maintained."
		echo ""
		echo "**Recommended Action:** Migrate to the maintained fork at [go.uber.org/mock](https://github.com/uber-go/mock)"
		echo ""
		echo "**Reference:** [golang/mock (archived)](https://github.com/golang/mock)"
		echo ""
		echo "## Repositories Using Deprecated golang/mock"
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
		echo "### Steps to Migrate from golang/mock to uber-go/mock"
		echo ""
		echo "1. **Update go.mod dependency:**"
		echo "   \`\`\`bash"
		echo "   go get go.uber.org/mock/mockgen@latest"
		echo "   go mod tidy"
		echo "   \`\`\`"
		echo ""
		echo "2. **Update import statements in your code:**"
		echo "   - Replace: \`github.com/golang/mock/gomock\`"
		echo "   - With: \`go.uber.org/mock/gomock\`"
		echo ""
		echo "3. **Update mockgen tool references:**"
		echo "   - If using \`go:generate\` directives, update the tool path"
		echo "   - If using Makefiles or scripts, update mockgen commands"
		echo ""
		echo "4. **Regenerate mocks:**"
		echo "   \`\`\`bash"
		echo "   go generate ./..."
		echo "   \`\`\`"
		echo ""
		echo "5. **Run tests to verify:**"
		echo "   \`\`\`bash"
		echo "   go test ./..."
		echo "   \`\`\`"
		echo ""
	} >"$OUTPUT_MD"

	echo -e "${GREEN}✅ Markdown report saved to: $OUTPUT_MD${RESET}"
	echo
else
	echo -e "${GREEN}${BOLD}✅ Great! No repositories found using deprecated golang/mock${RESET}"
	echo

	# Generate empty report
	{
		echo "# Deprecated golang/mock Usage Report"
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
		echo "- **Repositories using deprecated golang/mock:** ${FOUND_COUNT}"
		echo ""
		echo "## ✅ Result"
		echo ""
		echo "**Great!** No repositories found using the deprecated \`github.com/golang/mock\` package."
		echo ""
	} >"$OUTPUT_MD"

	echo "📝 Empty report saved to: $OUTPUT_MD"
	echo
fi

# Update tracking issue in telco-bot repo
echo -e "${BLUE}${BOLD}📋 Updating Central Tracking Issue${RESET}"
echo -e "${BLUE}─────────────────────────────────────────────────────${RESET}"
echo -e "${BLUE}   Building issue body with ${FOUND_COUNT} repositories using deprecated golang/mock...${RESET}"

# Build the issue body
ISSUE_BODY="# Deprecated golang/mock Usage Report

**Last Updated:** $(date -u '+%Y-%m-%d %H:%M:%S UTC')  
**Replacement:** [go.uber.org/mock](https://github.com/uber-go/mock)  
**Reference:** [golang/mock (archived)](https://github.com/golang/mock)

## Summary

- **Total Repositories Scanned:** ${TOTAL_REPOS}
- **Repositories Skipped (forks):** ${SKIPPED_FORKS}
- **Repositories Skipped (abandoned - no commits in 6 months):** ${SKIPPED_ABANDONED}
- **Repositories Skipped (no go.mod):** ${SKIPPED_NOGOMOD}
- **Repositories Actually Checked:** ${ACTUAL_SCANNED}
- **Repositories Using Deprecated golang/mock:** ${FOUND_COUNT}
- **Usage Percentage:** ${PERCENTAGE}

---

"

if [ $FOUND_COUNT -gt 0 ]; then
	# Group by organization and create tables
	for ORG_NAME in "${ORGS[@]}" "Individual Repositories"; do
		# Check if this org has any repos using deprecated golang/mock
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

			ISSUE_BODY+="**Repositories Using Deprecated golang/mock:** ${ORG_COUNT}

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

The \`github.com/golang/mock\` package was **archived in June 2023** and is no longer maintained.

### Migration Steps

1. **Update go.mod dependency:**
   \`\`\`bash
   go get go.uber.org/mock/mockgen@latest
   go mod tidy
   \`\`\`

2. **Update import statements:**
   - Replace: \`github.com/golang/mock/gomock\`
   - With: \`go.uber.org/mock/gomock\`

3. **Update mockgen tool references:**
   - Update \`go:generate\` directives
   - Update Makefiles or scripts

4. **Regenerate mocks:**
   \`\`\`bash
   go generate ./...
   \`\`\`

5. **Run tests:**
   \`\`\`bash
   go test ./...
   \`\`\`

### Resources

- [go.uber.org/mock (maintained fork)](https://github.com/uber-go/mock)
- [golang/mock (archived - June 2023)](https://github.com/golang/mock)
- [Migration Guide](https://github.com/uber-go/mock#migrating-from-gomock)

"
else
	ISSUE_BODY+="## ✅ All Clear!

All scanned Go repositories are either not using golang/mock or have been updated to the maintained fork. Great work! 🎉

"
fi

ISSUE_BODY+="---

*This issue is automatically updated by the [gomock-lookup.sh](https://github.com/${TRACKING_REPO}/blob/main/scripts/gomock-lookup.sh) script.*"

# Check if tracking issue exists
echo -e "${BLUE}   Issue body built successfully${RESET}"
echo -ne "   Checking for existing tracking issue... "
EXISTING_ISSUE=$(gh issue list --repo "$TRACKING_REPO" --search "in:title \"${TRACKING_ISSUE_TITLE}\"" --state all --json number,title,state --jq ".[] | select(.title == \"${TRACKING_ISSUE_TITLE}\") | .number" | head -1)

if [ -n "$EXISTING_ISSUE" ]; then
	echo -e "${GREEN}found (#${EXISTING_ISSUE})${RESET}"
	echo -ne "   Updating issue #${EXISTING_ISSUE}... "

	# Check if issue is closed and reopen it if there are repos using deprecated golang/mock
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

echo -e "${GREEN}${BOLD}✅ Scan completed successfully!${RESET}"
