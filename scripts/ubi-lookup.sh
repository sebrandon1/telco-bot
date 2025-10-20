#!/bin/bash

#===============================================================================
# UBI IMAGE USAGE SCANNER
#===============================================================================
#
# DESCRIPTION:
#   This script scans GitHub organizations for repositories that use specific
#   UBI (Universal Base Image) versions in their Dockerfiles or Containerfiles.
#   It helps identify repositories using outdated or EOL UBI images like ubi7.
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
#   ./ubi-lookup.sh --version ubi7
#   ./ubi-lookup.sh --version ubi7-minimal
#   ./ubi-lookup.sh --version ubi8 --org openshift
#   ./ubi-lookup.sh --version ubi9 --org redhat-best-practices-for-k8s
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
	echo -e "${BOLD}USAGE:${RESET}"
	echo "    $0 --version <ubi-version> [--org <organization>]"
	echo
	echo -e "${BOLD}OPTIONS:${RESET}"
	echo "    --version <version>    UBI version to search for (required)"
	echo "                          Examples: ubi7, ubi8, ubi9, ubi7-minimal, ubi8-minimal"
	echo
	echo "    --org <organization>   Scan only the specified organization (optional)"
	echo "                          If not provided, scans all default organizations:"
	echo "                          - redhat-best-practices-for-k8s"
	echo "                          - openshift"
	echo "                          - openshift-kni"
	echo "                          - redhat-openshift-ecosystem"
	echo "                          - redhatci"
	echo
	echo "    -h, --help            Show this help message"
	echo
	echo -e "${BOLD}EXAMPLES:${RESET}"
	echo "    # Scan all default organizations for ubi7"
	echo "    $0 --version ubi7"
	echo
	echo "    # Scan only openshift org for ubi7-minimal"
	echo "    $0 --version ubi7-minimal --org openshift"
	echo
	echo "    # Scan for ubi8 in a specific org"
	echo "    $0 --version ubi8 --org redhat-best-practices-for-k8s"
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

# Terminal colors
GREEN="\033[0;32m"
RED="\033[0;31m"
BLUE="\033[0;34m"
YELLOW="\033[0;33m"
BOLD="\033[1m"
RESET="\033[0m"

# Common Dockerfile/Containerfile paths to check
CONTAINER_FILES=("Dockerfile" "Containerfile" "build/Dockerfile" "docker/Dockerfile" ".dockerfiles/Dockerfile" "dockerfiles/Dockerfile")

# Track other UBI versions found (using temp file for bash 3.x compatibility)
UBI_VERSIONS_TEMP=$(mktemp)

echo -e "${BLUE}${BOLD}🔍 SCANNING REPOSITORIES FOR ${UBI_VERSION} IMAGE USAGE${RESET}"
echo -e "${BLUE}─────────────────────────────────────────────────────${RESET}"

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

		found=false
		found_in_file=""
		other_versions=""

		# Check each common container file location
		for file in "${CONTAINER_FILES[@]}"; do
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

		if $found; then
			echo -e "${GREEN}✓ USES ${UBI_VERSION} in ${found_in_file}${RESET}"
			echo "found" >>"$temp_results"
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
	if [ -f "$temp_results" ]; then
		ORG_FOUND=$(grep -c "found" "$temp_results")
		FOUND_COUNT=$((FOUND_COUNT + ORG_FOUND))
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

		# Get default branch for the repo
		echo -ne "   ${BLUE}[${INDIVIDUAL_COUNT}/${TOTAL_INDIVIDUAL}]${RESET} 📂 ${repo}... "
		branch=$(gh repo view "$repo" --json defaultBranchRef -q '.defaultBranchRef.name' 2>/dev/null)

		if [[ $? -ne 0 || -z "$branch" ]]; then
			echo -e "${RED}✗ Failed to fetch repo info${RESET}"
			continue
		fi

		echo -ne "on branch ${branch}... "

		found=false
		found_in_file=""
		other_versions=""

		# Check each common container file location
		for file in "${CONTAINER_FILES[@]}"; do
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

		if $found; then
			echo -e "${GREEN}✓ USES ${UBI_VERSION} in ${found_in_file}${RESET}"
			echo "found" >>"$temp_results"
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
	if [ -f "$temp_results" ]; then
		INDIVIDUAL_FOUND=$(grep -c "found" "$temp_results")
		FOUND_COUNT=$((FOUND_COUNT + INDIVIDUAL_FOUND))
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

# Final summary
echo -e "${BOLD}${BLUE}📈 FINAL RESULTS:${RESET}"
echo -e "${BOLD}   Total repositories scanned:${RESET} ${TOTAL_REPOS}"
echo -e "${BOLD}   Repositories using ${UBI_VERSION}:${RESET} ${GREEN}${FOUND_COUNT}${RESET}"

# Calculate percentage safely (avoid division by zero)
if [ $TOTAL_REPOS -gt 0 ]; then
	PERCENTAGE=$(awk "BEGIN { printf \"%.1f%%\", ($FOUND_COUNT/$TOTAL_REPOS)*100 }")
else
	PERCENTAGE="N/A (no repositories scanned)"
fi
echo -e "${BOLD}   Usage percentage:${RESET} ${PERCENTAGE}"

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
echo
