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
SKIPPED_NOGOMOD=0
SKIPPED_ABANDONED=0

# Cache files (shared with other scripts)
FORK_CACHE=".go-version-checker-forks.cache"
NOGOMOD_CACHE=".xcrypto-lookup-nogomod.cache"
ABANDONED_CACHE=".go-version-checker-abandoned.cache"
OUTPUT_MD="xcrypto-usage-report.md"

# Inactivity threshold (in days)
INACTIVITY_DAYS=180 # 6 months

# Create empty cache files if they don't exist
touch "$FORK_CACHE" "$NOGOMOD_CACHE" "$ABANDONED_CACHE"

#===============================================================================
# HELPER FUNCTIONS
#===============================================================================

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

# Helper function to check for PRs related to x/crypto migration (open, closed, or merged)
# Returns the LATEST (most recently updated) x/crypto-related PR
check_xcrypto_pr() {
	local repo="$1"

	# List all PRs (open, closed, merged) and filter for x/crypto-related keywords
	# Include updatedAt to sort by most recent
	local pr_search=$(gh pr list --repo "$repo" --state all --json number,title,url,state,mergedAt,updatedAt --limit 100 2>/dev/null)

	if [[ $? -ne 0 || -z "$pr_search" || "$pr_search" == "[]" ]]; then
		echo "none"
		return
	fi

	# Filter PRs that have x/crypto-related keywords in the title
	# Sort by updatedAt (most recent first) and take the first one
	# Return format: #123;URL;STATUS (STATUS = open/merged/closed)
	local pr_info=$(echo "$pr_search" | jq -r '[.[] | select(.title | test("x/crypto|golang.org/x/crypto|crypto/"; "i"))] | 
		sort_by(.updatedAt) | reverse | .[0] | 
		if . != null then
			if .mergedAt != null then
				"#" + (.number|tostring) + ";" + .url + ";merged"
			elif .state == "OPEN" then
				"#" + (.number|tostring) + ";" + .url + ";open"
			else
				"#" + (.number|tostring) + ";" + .url + ";closed"
			end
		else
			empty
		end')

	if [[ -n "$pr_info" ]]; then
		echo "$pr_info"
	else
		echo "none"
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

# Tracking issue configuration
TRACKING_REPO="redhat-best-practices-for-k8s/telco-bot"
TRACKING_ISSUE_TITLE="Tracking golang.org/x/crypto Direct Usage"

# Array to store repositories using x/crypto directly
declare -a XCRYPTO_REPOS

# Temporary file to store org-specific data for tracking issue (with last commit date and PR status)
ORG_DATA_FILE=$(mktemp)

echo -e "${BLUE}${BOLD}🔍 SCANNING REPOSITORIES FOR GOLANG.ORG/X/CRYPTO USAGE${RESET}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${RESET}"
echo -e "${YELLOW}⚠️  Note: Tracking direct dependencies on golang.org/x/crypto${RESET}"
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
			echo -e "${GREEN}✓ USES crypto directly${RESET}"
			echo "$repo" >>"$temp_results"
			XCRYPTO_REPOS+=("$repo")

			# Fetch last commit date from default branch for tracking issue
			last_commit=$(gh api "repos/${repo}/commits/${branch}" --jq '.commit.committer.date' 2>/dev/null || echo "unknown")

			# Check for PRs related to x/crypto migration
			pr_status=$(check_xcrypto_pr "$repo")

			# Store for org-specific data: org|repo|branch|last_commit|pr_status
			echo "$ORG_NAME|$repo|$branch|$last_commit|$pr_status" >>"$ORG_DATA_FILE"
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
			echo -e "${GREEN}✓ USES crypto directly${RESET}"
			echo "$repo" >>"$temp_results"
			XCRYPTO_REPOS+=("$repo")

			# Fetch last commit date from default branch for tracking issue
			last_commit=$(gh api "repos/${repo}/commits/${branch}" --jq '.commit.committer.date' 2>/dev/null || echo "unknown")

			# Check for PRs related to x/crypto migration
			pr_status=$(check_xcrypto_pr "$repo")

			# Store for org-specific data: org|repo|branch|last_commit|pr_status
			echo "Individual Repositories|$repo|$branch|$last_commit|$pr_status" >>"$ORG_DATA_FILE"
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
echo

# Display table of repositories using x/crypto directly
if [ ${#XCRYPTO_REPOS[@]} -gt 0 ]; then
	echo -e "${GREEN}${BOLD}📦 REPOSITORIES USING GOLANG.ORG/X/CRYPTO DIRECTLY:${RESET}"
	echo -e "${GREEN}═══════════════════════════════════════════════════════════${RESET}"
	echo
	printf "${BOLD}%-60s${RESET} ${BOLD}%s${RESET}\n" "Repository" "URL"
	printf "%s\n" "─────────────────────────────────────────────────────────────────────────────────────────────"

	for repo in "${XCRYPTO_REPOS[@]}"; do
		printf "%-60s https://github.com/%s\n" "$repo" "$repo"
	done

	echo
	echo -e "${YELLOW}${BOLD}💡 NOTE:${RESET}"
	echo -e "${YELLOW}   These repositories directly depend on golang.org/x/crypto${RESET}"
	echo -e "${YELLOW}   This is informational - x/crypto is a valid and maintained package${RESET}"
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
		echo "| # | Repository | GitHub URL |"
		echo "|---|------------|------------|"

		counter=1
		for repo in "${XCRYPTO_REPOS[@]}"; do
			echo "| $counter | \`$repo\` | [View on GitHub](https://github.com/$repo) |"
			counter=$((counter + 1))
		done

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

# Build the issue body
ISSUE_BODY="# golang.org/x/crypto Direct Usage Report

**Last Updated:** $(date -u '+%Y-%m-%d %H:%M:%S UTC')  
**Package:** [golang.org/x/crypto](https://pkg.go.dev/golang.org/x/crypto)  
**Status:** Actively maintained by the Go team

## Summary

- **Total Repositories Scanned:** ${TOTAL_REPOS}
- **Repositories Skipped (forks):** ${SKIPPED_FORKS}
- **Repositories Skipped (abandoned - no commits in 6 months):** ${SKIPPED_ABANDONED}
- **Repositories Skipped (no go.mod):** ${SKIPPED_NOGOMOD}
- **Repositories Actually Checked:** ${ACTUAL_SCANNED}
- **Repositories Using x/crypto Directly:** ${FOUND_COUNT}
- **Usage Percentage:** ${PERCENTAGE}

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
				# Format PR status with emoji indicators
				if [ "$pr_status" = "none" ] || [ -z "$pr_status" ]; then
					pr_display="—"
				else
					# Parse pr_status format: #123;https://github.com/org/repo/pull/123;status
					pr_number=$(echo "$pr_status" | cut -d';' -f1)
					pr_url=$(echo "$pr_status" | cut -d';' -f2)
					pr_state=$(echo "$pr_status" | cut -d';' -f3)

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
				fi
				echo "| [\`${repo_display}\`](https://github.com/${repo}) | \`${branch}\` | ${last_commit_display} | ${pr_display} | [View Repository](https://github.com/${repo}) |"
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

# Cleanup temporary files
rm -f "$ORG_DATA_FILE"

echo -e "${GREEN}${BOLD}✅ Scan completed successfully!${RESET}"
