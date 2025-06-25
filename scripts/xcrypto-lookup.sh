#!/bin/bash

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
