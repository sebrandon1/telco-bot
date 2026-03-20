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

# Load shared library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# Prerequisite checks
echo "Checking prerequisites..."
require_tool gh curl
check_gh_auth
echo -e "${GREEN}All prerequisites met${RESET}"
echo

# Configuration
ORGS=("${DEFAULT_ORGS[@]}")
LIMIT=$DEFAULT_LIMIT
INACTIVITY_DAYS=$DEFAULT_INACTIVITY_DAYS
TRACKING_ISSUE_TITLE="Tracking Deprecated golang/mock Usage"
OUTPUT_MD="gomock-usage-report.md"

# Counters
FOUND_COUNT=0
TOTAL_REPOS=0
SKIPPED_FORKS=0
SKIPPED_NOGOMOD=0
SKIPPED_ABANDONED=0

# Initialize caches
init_cache_paths
load_shared_caches

# Calculate cutoff date
CUTOFF_DATE=$(calculate_cutoff_date "$INACTIVITY_DAYS")

# Temporary file for newly discovered no-go.mod repos
NOGOMOD_TEMP=$(mktemp)
ORG_DATA_FILE=$(mktemp)
trap 'rm -f "$NOGOMOD_TEMP" "$ORG_DATA_FILE" "${ORG_DATA_FILE}.table"' EXIT

# Array to store repositories using deprecated golang/mock
declare -a DEPRECATED_REPOS

#===============================================================================
# SCRIPT-SPECIFIC HELPERS
#===============================================================================

# Check for PRs related to gomock migration (open, closed, or merged)
check_gomock_pr() {
	local repo="$1"

	# Use gh search prs to search ALL PRs (not just recent 100)
	# First try migration-specific terms to avoid false positives
	local pr_search
	pr_search=$(gh search prs --repo "$repo" --json number,title,url,state \
		--limit 10 -- "mockgen deprecated" 2>/dev/null)

	# If no results, try broader but still targeted search
	if [[ $? -ne 0 || -z "$pr_search" || "$pr_search" == "[]" ]]; then
		pr_search=$(gh search prs --repo "$repo" --json number,title,url,state \
			--limit 10 -- "uber-go/mock" 2>/dev/null)
	fi

	# Last resort: try golang/mock
	if [[ $? -ne 0 || -z "$pr_search" || "$pr_search" == "[]" ]]; then
		pr_search=$(gh search prs --repo "$repo" --json number,title,url,state \
			--limit 10 -- "golang/mock" 2>/dev/null)
	fi

	if [[ $? -ne 0 || -z "$pr_search" || "$pr_search" == "[]" ]]; then
		echo "none"
		return
	fi

	# Filter by title relevance - prefer migration PRs over incidental mentions
	# gh search prs returns state as "open"/"closed" (lowercase), and no mergedAt field
	local pr_info
	pr_info=$(echo "$pr_search" | jq -r '
		# First try to find migration-specific PRs
		[.[] | select(.title | test("deprecat|migrate|replace|switch.*mock|uber.*mock|mock.*uber"; "i"))] as $migration |
		# Fall back to any PR mentioning gomock/mockgen
		[.[] | select(.title | test("gomock|mockgen|golang/mock|uber-go/mock|go.uber.org/mock"; "i"))] as $all |
		(if ($migration | length) > 0 then $migration[0] else ($all[0] // empty) end) |
		"#" + (.number|tostring) + ";" + .url + ";" + .state
	' 2>/dev/null)

	if [[ -n "$pr_info" && "$pr_info" != "null" ]]; then
		# gh search prs reports merged PRs as "closed" - check if actually merged
		local pr_state
		pr_state=$(echo "$pr_info" | cut -d';' -f3)
		if [[ "$pr_state" == "closed" ]]; then
			local pr_number
			pr_number=$(echo "$pr_info" | cut -d';' -f1 | sed 's/#//')
			local merged_at
			merged_at=$(gh pr view "$pr_number" --repo "$repo" --json mergedAt --jq '.mergedAt' 2>/dev/null)
			if [[ -n "$merged_at" && "$merged_at" != "null" && "$merged_at" != "" ]]; then
				pr_info=$(echo "$pr_info" | sed 's/;closed$/;merged/')
			fi
		fi
		echo "$pr_info"
	else
		echo "none"
	fi
}

# Check if an open PR needs a rebase
check_pr_needs_rebase() {
	local repo="$1"
	local pr_number="$2"

	local pr_details
	pr_details=$(gh pr view "$pr_number" --repo "$repo" --json mergeable,mergeStateStatus 2>/dev/null)

	if [[ $? -ne 0 || -z "$pr_details" ]]; then
		echo "unknown"
		return
	fi

	local mergeable merge_state
	mergeable=$(echo "$pr_details" | jq -r '.mergeable // "UNKNOWN"')
	merge_state=$(echo "$pr_details" | jq -r '.mergeStateStatus // "UNKNOWN"')

	if [ "$merge_state" = "BEHIND" ] || [ "$merge_state" = "DIRTY" ]; then
		echo "needs_rebase"
	elif [ "$mergeable" = "CONFLICTING" ]; then
		echo "has_conflicts"
	elif [ "$merge_state" = "CLEAN" ] || [ "$merge_state" = "UNSTABLE" ]; then
		echo "up_to_date"
	else
		echo "unknown"
	fi
}

# Scan a single repo for deprecated golang/mock usage.
# Usage: scan_repo_for_gomock "org/repo" "branch" "OrgLabel"
# Returns 0 if deprecated usage found, 1 otherwise.
scan_repo_for_gomock() {
	local repo="$1"
	local branch="$2"
	local org_label="$3"

	local raw_url="https://raw.githubusercontent.com/$repo/$branch/go.mod"
	local go_mod
	go_mod=$(curl -s -f "$raw_url")

	if [[ $? -ne 0 ]]; then
		echo -e "${YELLOW}no go.mod (cached)${RESET}"
		echo "$repo" >>"$NOGOMOD_TEMP"
		SKIPPED_NOGOMOD=$((SKIPPED_NOGOMOD + 1))
		return 1
	fi

	if echo "$go_mod" | grep -E '^[[:space:]]*github\.com/golang/mock' | grep -vq '// indirect'; then
		echo -e "${RED}USES DEPRECATED golang/mock${RESET}"
		DEPRECATED_REPOS+=("$repo")

		local last_commit
		last_commit=$(gh api "repos/${repo}/commits/${branch}" --jq '.commit.committer.date' 2>/dev/null || echo "unknown")

		local pr_status pr_rebase_status=""
		pr_status=$(check_gomock_pr "$repo")

		if [[ "$pr_status" != "none" ]]; then
			local pr_state
			pr_state=$(echo "$pr_status" | cut -d';' -f3)
			if [ "$pr_state" = "open" ]; then
				local pr_number
				pr_number=$(echo "$pr_status" | cut -d';' -f1 | sed 's/#//')
				pr_rebase_status=$(check_pr_needs_rebase "$repo" "$pr_number")
			fi
		fi

		echo "$org_label|$repo|$branch|$last_commit|$pr_status|$pr_rebase_status" >>"$ORG_DATA_FILE"
		return 0
	else
		echo -e "${GREEN}No deprecated usage${RESET}"
		return 1
	fi
}

# Skip-check a repo against caches and abandoned status.
# Echoes skip reason and returns 0 if skipped, 1 if should scan.
skip_check_repo() {
	local repo="$1"
	local branch="$2"
	local is_fork="$3"

	# Fork check
	if is_in_cache "$repo" "$FORK_CACHE" || [ "$is_fork" = "true" ]; then
		echo -e "${BLUE}skipped (fork)${RESET}"
		SKIPPED_FORKS=$((SKIPPED_FORKS + 1))
		if [ "$is_fork" = "true" ] && ! is_in_cache "$repo" "$FORK_CACHE"; then
			echo "$repo" >>"$FORK_CACHE"
		fi
		return 0
	fi

	# Abandoned cache check
	if is_in_cache "$repo" "$ABANDONED_CACHE"; then
		echo -e "${BLUE}skipped (abandoned)${RESET}"
		SKIPPED_ABANDONED=$((SKIPPED_ABANDONED + 1))
		return 0
	fi

	# Live abandoned check
	if is_repo_abandoned "$repo" "$branch"; then
		echo -e "${BLUE}skipped (abandoned - no recent commits)${RESET}"
		echo "$repo" >>"$ABANDONED_CACHE"
		SKIPPED_ABANDONED=$((SKIPPED_ABANDONED + 1))
		return 0
	fi

	# No-go.mod cache check
	if is_in_cache "$repo" "$NOGOMOD_CACHE"; then
		echo -e "${BLUE}skipped (no go.mod)${RESET}"
		SKIPPED_NOGOMOD=$((SKIPPED_NOGOMOD + 1))
		return 0
	fi

	return 1
}

#===============================================================================
# MAIN SCAN
#===============================================================================

echo -e "${BLUE}${BOLD}SCANNING REPOSITORIES FOR DEPRECATED GOLANG/MOCK USAGE${RESET}"
echo -e "${BLUE}=======================================================${RESET}"
echo -e "${YELLOW}Note: github.com/golang/mock was archived in June 2023${RESET}"
echo -e "${YELLOW}  Recommended replacement: go.uber.org/mock${RESET}"
echo -e "${BLUE}Skipping repos with no commits since: ${CUTOFF_DATE:0:10}${RESET}"
echo -e "${BLUE}=======================================================${RESET}"
echo

for ORG_NAME in "${ORGS[@]}"; do
	echo -e "${YELLOW}${BOLD}Organization: ${ORG_NAME}${RESET}"

	echo -e "${BLUE}   Fetching repository list...${RESET}"
	REPOS=$(gh repo list "$ORG_NAME" --limit "$LIMIT" --json nameWithOwner,defaultBranchRef,isArchived,isFork -q '.[] | select(.isArchived == false) | .nameWithOwner + " " + .defaultBranchRef.name + " " + (.isFork | tostring)')
	REPO_COUNT=$(echo "$REPOS" | grep -v '^$' | wc -l | tr -d ' ')
	TOTAL_REPOS=$((TOTAL_REPOS + REPO_COUNT))

	echo -e "${BLUE}   Found ${REPO_COUNT} active repositories to scan${RESET}"
	echo

	ORG_FOUND=0
	temp_results=$(mktemp)

	while read -r repo branch is_fork; do
		[[ -z "$repo" ]] && continue

		echo -ne "   ${repo} on branch ${branch}... "

		if skip_check_repo "$repo" "$branch" "$is_fork"; then
			continue
		fi

		# Pass ORG_NAME as first arg for ORG_DATA_FILE grouping
		if scan_repo_for_gomock "$repo" "$branch" "$ORG_NAME"; then
			echo "$repo" >>"$temp_results"
		fi
	done <<<"$REPOS"

	if [ -f "$temp_results" ] && [ -s "$temp_results" ]; then
		ORG_FOUND=$(wc -l <"$temp_results" | tr -d ' ')
		FOUND_COUNT=$((FOUND_COUNT + ORG_FOUND))
	fi
	rm -f "$temp_results"

	echo
	echo -e "${YELLOW}${BOLD}Summary for ${ORG_NAME}:${RESET}"
	echo -e "   ${RED}${ORG_FOUND}${RESET} repositories using deprecated github.com/golang/mock"
	echo -e "${BLUE}-----------------------------------------------------${RESET}"
	echo
done

# Scan individual repositories from gomock-repo-list.txt
REPO_LIST_FILE="gomock-repo-list.txt"
if [ -f "$REPO_LIST_FILE" ]; then
	echo -e "${YELLOW}${BOLD}Individual Repositories from ${REPO_LIST_FILE}${RESET}"

	INDIVIDUAL_FOUND=0
	INDIVIDUAL_COUNT=0
	temp_results=$(mktemp)

	while IFS= read -r repo; do
		INDIVIDUAL_COUNT=$((INDIVIDUAL_COUNT + 1))

		echo -ne "   ${repo}... "
		repo_info=$(gh repo view "$repo" --json defaultBranchRef,isFork 2>/dev/null)

		if [[ $? -ne 0 || -z "$repo_info" ]]; then
			echo -e "${RED}Failed to fetch repo info${RESET}"
			continue
		fi

		branch=$(echo "$repo_info" | jq -r '.defaultBranchRef.name')
		is_fork=$(echo "$repo_info" | jq -r '.isFork')

		echo -ne "on branch ${branch}... "

		if skip_check_repo "$repo" "$branch" "$is_fork"; then
			continue
		fi

		if scan_repo_for_gomock "$repo" "$branch" "Individual Repositories"; then
			echo "$repo" >>"$temp_results"
		fi
	done < <(read_repo_list "$REPO_LIST_FILE")

	if [ -f "$temp_results" ] && [ -s "$temp_results" ]; then
		INDIVIDUAL_FOUND=$(wc -l <"$temp_results" | tr -d ' ')
		FOUND_COUNT=$((FOUND_COUNT + INDIVIDUAL_FOUND))
		TOTAL_REPOS=$((TOTAL_REPOS + INDIVIDUAL_COUNT))
	else
		TOTAL_REPOS=$((TOTAL_REPOS + INDIVIDUAL_COUNT))
	fi
	rm -f "$temp_results"

	echo
	echo -e "${YELLOW}${BOLD}Summary for Individual Repositories:${RESET}"
	echo -e "   ${RED}${INDIVIDUAL_FOUND}${RESET} repositories using deprecated github.com/golang/mock (out of ${INDIVIDUAL_COUNT} scanned)"
	echo -e "${BLUE}-----------------------------------------------------${RESET}"
	echo
fi

# Update caches
merge_cache "$NOGOMOD_TEMP" "$NOGOMOD_CACHE" "no-go.mod"
dedup_cache "$FORK_CACHE"
dedup_cache "$ABANDONED_CACHE"

# Final summary
echo -e "${BOLD}${BLUE}FINAL RESULTS:${RESET}"
echo -e "${BOLD}   Total repositories scanned:${RESET} ${TOTAL_REPOS}"
echo -e "${BOLD}   Repositories skipped (forks):${RESET} ${BLUE}${SKIPPED_FORKS}${RESET}"
echo -e "${BOLD}   Repositories skipped (abandoned):${RESET} ${BLUE}${SKIPPED_ABANDONED}${RESET}"
echo -e "${BOLD}   Repositories skipped (no go.mod):${RESET} ${BLUE}${SKIPPED_NOGOMOD}${RESET}"
echo -e "${BOLD}   Repositories with deprecated golang/mock:${RESET} ${RED}${FOUND_COUNT}${RESET}"

ACTUAL_SCANNED=$((TOTAL_REPOS - SKIPPED_FORKS - SKIPPED_ABANDONED - SKIPPED_NOGOMOD))
if [ $ACTUAL_SCANNED -gt 0 ]; then
	PERCENTAGE=$(awk "BEGIN { printf \"%.1f%%\", ($FOUND_COUNT/$ACTUAL_SCANNED)*100 }")
else
	PERCENTAGE="N/A (no repositories scanned)"
fi
echo -e "${BOLD}   Usage percentage:${RESET} ${PERCENTAGE}"
echo

#===============================================================================
# REPORTS
#===============================================================================

if [ ${#DEPRECATED_REPOS[@]} -gt 0 ]; then
	echo -e "${RED}${BOLD}REPOSITORIES USING DEPRECATED GOLANG/MOCK:${RESET}"
	echo -e "${RED}=======================================================${RESET}"
	echo
	printf "${BOLD}%-60s${RESET} ${BOLD}%s${RESET}\n" "Repository" "URL"
	printf "%s\n" "-------------------------------------------------------------------------------------------------------------"

	for repo in "${DEPRECATED_REPOS[@]}"; do
		printf "%-60s https://github.com/%s\n" "$repo" "$repo"
	done

	echo
	echo -e "${YELLOW}${BOLD}RECOMMENDATION:${RESET}"
	echo -e "${YELLOW}   Migrate from github.com/golang/mock to go.uber.org/mock${RESET}"
	echo -e "${YELLOW}   Reference: https://github.com/golang/mock (archived)${RESET}"
	echo

	# Generate Markdown report
	echo "Generating markdown report: $OUTPUT_MD"
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
		echo "## Important Notice"
		echo ""
		echo "The \`github.com/golang/mock\` package was **archived in June 2023** and is no longer maintained."
		echo ""
		echo "**Recommended Action:** Migrate to the maintained fork at [go.uber.org/mock](https://github.com/uber-go/mock)"
		echo ""
		echo "**Reference:** [golang/mock (archived)](https://github.com/golang/mock)"
		echo ""
		echo "## Repositories Using Deprecated golang/mock"
		echo ""
		echo "| # | Repository |"
		echo "|---|------------|"

		counter=1
		for repo in "${DEPRECATED_REPOS[@]}"; do
			echo "| $counter | [\`$repo\`](https://github.com/$repo) |"
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

	echo -e "${GREEN}Markdown report saved to: $OUTPUT_MD${RESET}"
	echo
else
	echo -e "${GREEN}${BOLD}Great! No repositories found using deprecated golang/mock${RESET}"
	echo

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
		echo "## Result"
		echo ""
		echo "**Great!** No repositories found using the deprecated \`github.com/golang/mock\` package."
		echo ""
	} >"$OUTPUT_MD"

	echo "Empty report saved to: $OUTPUT_MD"
	echo
fi

#===============================================================================
# TRACKING ISSUE
#===============================================================================

echo -e "${BLUE}${BOLD}Updating Central Tracking Issue${RESET}"
echo -e "${BLUE}-----------------------------------------------------${RESET}"
echo -e "${BLUE}   Building issue body with ${FOUND_COUNT} repositories using deprecated golang/mock...${RESET}"

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
	for ORG_NAME in "${ORGS[@]}" "Individual Repositories"; do
		ORG_REPOS=$(grep "^${ORG_NAME}|" "$ORG_DATA_FILE" 2>/dev/null || true)

		if [ -n "$ORG_REPOS" ]; then
			ORG_COUNT=$(echo "$ORG_REPOS" | wc -l | tr -d ' ')

			if [ "$ORG_NAME" = "Individual Repositories" ]; then
				ISSUE_BODY+="## ${ORG_NAME}

"
			else
				ISSUE_BODY+="## [${ORG_NAME}](https://github.com/${ORG_NAME})

"
			fi

			ISSUE_BODY+="**Repositories Using Deprecated golang/mock:** ${ORG_COUNT}

| Repository | Last Updated | PR Status |
|------------|--------------|-----------|
"

			echo "$ORG_REPOS" | sort -t'|' -k4 -r | while IFS='|' read -r org repo branch last_commit pr_status pr_rebase_status; do
				repo_name="${repo##*/}"
				repo_display=$(echo "$repo_name" | sed 's/|/\\|/g')
				last_commit_display=$(format_date "$last_commit")

				if [ "$pr_status" = "none" ] || [ -z "$pr_status" ]; then
					pr_display="—"
				else
					pr_number=$(echo "$pr_status" | cut -d';' -f1)
					pr_url=$(echo "$pr_status" | cut -d';' -f2)
					pr_state=$(echo "$pr_status" | cut -d';' -f3)

					case "$pr_state" in
					"merged") pr_emoji="✅" ;;
					"open")
						pr_emoji="🔄"
						if [ -n "$pr_rebase_status" ]; then
							case "$pr_rebase_status" in
							"needs_rebase") pr_emoji="⚠️ 🔄" ;;
							"has_conflicts") pr_emoji="❌ 🔄" ;;
							"up_to_date") pr_emoji="✅ 🔄" ;;
							esac
						fi
						;;
					"closed") pr_emoji="❌" ;;
					*) pr_emoji="" ;;
					esac

					pr_display="${pr_emoji} [${pr_number}](${pr_url})"
				fi
				echo "| [\`${repo_display}\`](https://github.com/${repo}) | ${last_commit_display} | ${pr_display} |"
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
	ISSUE_BODY+="## All Clear!

All scanned Go repositories are either not using golang/mock or have been updated to the maintained fork. Great work!

"
fi

ISSUE_BODY+="---

*This issue is automatically updated by the [gomock-lookup.sh](https://github.com/${TRACKING_REPO}/blob/main/scripts/gomock-lookup.sh) script.*"

echo -e "${BLUE}   Issue body built successfully${RESET}"
upsert_tracking_issue "$TRACKING_ISSUE_TITLE" "$ISSUE_BODY" "$FOUND_COUNT"

echo
echo -e "${GREEN}${BOLD}Scan completed successfully!${RESET}"
