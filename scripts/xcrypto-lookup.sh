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
# CONFIGURATION:
#   You can customize which organizations to scan by editing the ORGS array
#   below (line ~45). Add or remove organization names as needed:
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
#
# LIMITATIONS:
#   - Limited to 1000 repositories per organization (configurable via LIMIT)
#   - Only detects direct dependencies, not transitive usage
#   - Requires public access to go.mod files or appropriate permissions
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

# Terminal colors
GREEN="\033[0;32m"
RED="\033[0;31m"
BLUE="\033[0;34m"
YELLOW="\033[0;33m"
BOLD="\033[1m"
RESET="\033[0m"

echo -e "${BLUE}${BOLD}🔍 SCANNING REPOSITORIES FOR GOLANG.ORG/X/CRYPTO USAGE${RESET}"
echo -e "${BLUE}─────────────────────────────────────────────────────${RESET}"

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

		# Fetch go.mod raw content from default branch
		raw_url="https://raw.githubusercontent.com/$repo/$branch/go.mod"
		go_mod=$(curl -s -f "$raw_url")

		if [[ $? -ne 0 ]]; then
			echo -e "${YELLOW}no go.mod${RESET}"
			continue
		fi

		# Check for direct dependency (exclude // indirect)
		if echo "$go_mod" | grep -E '^require[[:space:]]+golang.org/x/crypto' | grep -vq '// indirect'; then
			echo -e "${GREEN}✓ USES crypto directly${RESET}"
			echo "found" >>"$temp_results"
		else
			echo -e "${RED}✗ NO direct usage${RESET}"
		fi
	done <<<"$REPOS"

	# Count the results
	if [ -f "$temp_results" ]; then
		ORG_FOUND=$(grep -c "found" "$temp_results")
		FOUND_COUNT=$((FOUND_COUNT + ORG_FOUND))
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

		# Get default branch for the repo
		echo -ne "   📂 ${repo}... "
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
			continue
		fi

		# Check for direct dependency (exclude // indirect)
		if echo "$go_mod" | grep -E '^require[[:space:]]+golang.org/x/crypto' | grep -vq '// indirect'; then
			echo -e "${GREEN}✓ USES crypto directly${RESET}"
			echo "found" >>"$temp_results"
		else
			echo -e "${RED}✗ NO direct usage${RESET}"
		fi
	done <"$REPO_LIST_FILE"

	# Count the results
	if [ -f "$temp_results" ]; then
		INDIVIDUAL_FOUND=$(grep -c "found" "$temp_results")
		FOUND_COUNT=$((FOUND_COUNT + INDIVIDUAL_FOUND))
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

# Final summary
echo -e "${BOLD}${BLUE}📈 FINAL RESULTS:${RESET}"
echo -e "${BOLD}   Total repositories scanned:${RESET} ${TOTAL_REPOS}"
echo -e "${BOLD}   Repositories with direct crypto usage:${RESET} ${GREEN}${FOUND_COUNT}${RESET}"

# Calculate percentage safely (avoid division by zero)
if [ $TOTAL_REPOS -gt 0 ]; then
	PERCENTAGE=$(awk "BEGIN { printf \"%.1f%%\", ($FOUND_COUNT/$TOTAL_REPOS)*100 }")
else
	PERCENTAGE="N/A (no repositories scanned)"
fi
echo -e "${BOLD}   Usage percentage:${RESET} ${PERCENTAGE}"
echo
