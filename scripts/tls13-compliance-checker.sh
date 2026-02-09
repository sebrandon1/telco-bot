#!/bin/bash

#===============================================================================
# TLS 1.3 COMPLIANCE CHECKER (Clone-Based)
#===============================================================================
#
# DESCRIPTION:
#   This script scans GitHub organizations for repositories with TLS
#   configuration issues and anti-patterns. It identifies Go projects with
#   insecure TLS settings, weak version constraints, and deprecated options.
#
#   Uses local clones for fast, rate-limit-free scanning instead of GitHub
#   Code Search API.
#
# SEVERITY LEVELS:
#
#   CRITICAL - InsecureSkipVerify: true
#     What: Disables TLS certificate verification entirely
#     Why:  Allows man-in-the-middle (MITM) attacks - an attacker can intercept
#           and modify traffic without detection. The client accepts ANY certificate,
#           including self-signed or expired ones from malicious actors.
#     Risk: Complete loss of TLS security guarantees. Credentials, tokens, and
#           sensitive data can be stolen or modified in transit.
#     Action: Remove InsecureSkipVerify or set to false. Use proper CA certificates.
#
#   HIGH - MinVersion/MaxVersion set to TLS 1.0 or 1.1
#     What: Allows or requires connections using TLS 1.0 or 1.1
#     Why:  These protocol versions have known cryptographic vulnerabilities:
#           - POODLE (Padding Oracle On Downgraded Legacy Encryption)
#           - BEAST (Browser Exploit Against SSL/TLS)
#           - Weak cipher suites with no forward secrecy
#     Risk: Attackers can exploit protocol weaknesses to decrypt traffic.
#           Many compliance standards (PCI-DSS, HIPAA) prohibit TLS < 1.2.
#     Action: Set MinVersion to tls.VersionTLS12 or higher.
#
#   MEDIUM - MaxVersion set to TLS 1.2
#     What: Caps the maximum TLS version, preventing TLS 1.3 negotiation
#     Why:  TLS 1.3 provides significant security improvements:
#           - Removes obsolete/insecure cryptographic algorithms
#           - Faster handshake (1-RTT vs 2-RTT)
#           - Better forward secrecy guarantees
#           - Encrypted handshake (hides more metadata)
#     Risk: Missing security benefits of TLS 1.3. May indicate outdated code
#           or unnecessary compatibility constraints.
#     Action: Remove MaxVersion unless there's a specific compatibility need.
#
#   INFO - MinVersion set to TLS 1.3
#     What: Requires TLS 1.3 for all connections (rejects TLS 1.2)
#     Why:  While TLS 1.3 is more secure, requiring it may break compatibility
#           with older clients, load balancers, or proxies that only support TLS 1.2.
#     Risk: Connection failures with legacy systems. Generally acceptable for
#           modern internal services.
#     Action: Verify all clients support TLS 1.3 before requiring it.
#
#   INFO - PreferServerCipherSuites: true
#     What: Instructs server to prefer its own cipher suite order over client's
#     Why:  Deprecated in Go 1.17+ and now a no-op. Go's crypto/tls automatically
#           selects the most secure mutually-supported cipher suite.
#     Risk: None - this is just dead code that should be cleaned up.
#     Action: Remove the setting (it has no effect in Go 1.17+).
#
# PREREQUISITES:
#   1. GitHub CLI (gh) must be installed on your system
#      - Install: https://cli.github.com/
#      - macOS: brew install gh
#      - Linux: See https://github.com/cli/cli/blob/trunk/docs/install_linux.md
#   2. GitHub CLI must be authenticated with sufficient permissions
#      - Run: gh auth login
#      - Requires read access to repositories in target organizations
#   3. git must be available for cloning/updating repositories (clone mode only)
#   4. grep and jq must be available
#
# USAGE:
#   ./tls13-compliance-checker.sh [OPTIONS]
#
# OPTIONS:
#   -h, --help          Show this help message and exit
#   -f, --force         Force refresh (ignore cache age)
#   --no-tracking       Skip updating the central tracking issue
#   --mode <api|clone>  Scanning mode (default: clone)
#                       - clone: Clone repos locally and scan with grep (faster, more accurate)
#                       - api: Use GitHub Code Search API (no disk needed, for CI/CD)
#
# TRACKING ISSUE:
#   The script maintains a central tracking issue in the telco-bot repo
#   (https://github.com/redhat-best-practices-for-k8s/telco-bot/issues)
#   titled "Tracking TLS Configuration Compliance". This issue is
#   automatically created if it doesn't exist and updated with each run.
#
# CONFIGURATION:
#   You can customize which organizations to scan by editing the ORGS array
#   below. Add or remove organization names as needed.
#
#   Repositories can be excluded by adding them to tls13-repo-blocklist.txt
#   (one per line). Supported formats:
#     - owner/repo
#     - github.com/owner/repo
#     - https://github.com/owner/repo
#
# OUTPUT:
#   The script provides:
#   - Real-time progress as it scans each repository
#   - Per-organization summary of findings
#   - Final summary with counts by severity level
#   - Color-coded output for easy reading
#   - Markdown report file (tls13-compliance-report.md)
#   - Automatic creation/update of central tracking issue in telco-bot repo
#
# PERFORMANCE:
#   Clone mode (default, recommended for local use):
#   - No API rate limits during grep scanning
#   - ~1-2 seconds per repo after initial clone
#   - Full scan of 200+ repos in 5-10 minutes
#   - Clones persist for faster subsequent runs
#   - Most accurate pattern matching
#
#   API mode (recommended for GitHub Actions):
#   - No disk space required (no cloning)
#   - Rate limited to ~10 code searches per minute
#   - Verifies matches by fetching file content
#   - May miss some edge cases due to search limitations
#   - Slower but works in CI/CD environments
#
# LIMITATIONS:
#   - Limited to 1000 repositories per organization
#   - Excludes vendor/, testdata/, mocks/, test/, tests/, e2e/, testing/,
#     mock/, fakes/, fixtures/, and *_test.go files
#===============================================================================

# Terminal colors
GREEN="\033[0;32m"
RED="\033[0;31m"
BLUE="\033[0;34m"
YELLOW="\033[0;33m"
BOLD="\033[1m"
RESET="\033[0m"

#===============================================================================
# HELP MENU
#===============================================================================

show_help() {
	echo -e "${BOLD}TLS 1.3 COMPLIANCE CHECKER (Clone-Based)${RESET}"
	echo
	echo -e "${BOLD}USAGE:${RESET}"
	echo "    $(basename "$0") [OPTIONS]"
	echo
	echo -e "${BOLD}DESCRIPTION:${RESET}"
	echo "    Scans GitHub organizations for repositories with TLS configuration"
	echo "    issues and anti-patterns. Identifies insecure settings like"
	echo "    InsecureSkipVerify, weak TLS versions, and deprecated options."
	echo
	echo -e "${BOLD}OPTIONS:${RESET}"
	echo "    -h, --help          Show this help message and exit"
	echo "    -f, --force         Force refresh cache (ignore cache age)"
	echo "    --no-tracking       Skip updating the central tracking issue"
	echo "    --mode <api|clone>  Scanning mode (default: clone)"
	echo "                        - clone: Clone repos locally, scan with grep"
	echo "                        - api: Use GitHub Code Search (for CI/CD)"
	echo
	echo -e "${BOLD}SEVERITY LEVELS:${RESET}"
	echo "    CRITICAL    InsecureSkipVerify: true (MITM vulnerability)"
	echo "    HIGH        TLS 1.0/1.1 MinVersion or MaxVersion"
	echo "    MEDIUM      MaxVersion capped at TLS 1.2"
	echo "    INFO        MinVersion forced to TLS 1.3, or PreferServerCipherSuites"
	echo "                (deprecated in Go 1.17+)"
	echo
	echo -e "${BOLD}PREREQUISITES:${RESET}"
	echo "    - GitHub CLI (gh) must be installed and authenticated"
	echo "      Install: brew install gh (macOS) or https://cli.github.com/"
	echo "      Auth: gh auth login"
	echo "    - git must be available (clone mode only)"
	echo
	echo -e "${BOLD}CONFIGURATION:${RESET}"
	echo "    Organizations scanned:"
	echo "        redhat-best-practices-for-k8s, openshift, openshift-kni,"
	echo "        redhat-openshift-ecosystem, redhatci"
	echo
	echo "    Repositories can be excluded by adding them to:"
	echo "        scripts/tls13-repo-blocklist.txt"
	echo
	echo -e "${BOLD}OUTPUT:${RESET}"
	echo "    - Real-time progress and per-organization summaries"
	echo "    - Findings categorized by severity level"
	echo "    - Markdown report: tls13-compliance-report.md"
	echo "    - Auto-updates tracking issue in telco-bot repo"
	echo
	echo -e "${BOLD}CACHES:${RESET}"
	echo "    Uses shared caches to skip known forks, abandoned repos, and"
	echo "    repos without go.mod files. Caches are stored in:"
	echo "        scripts/caches/"
	echo
	echo -e "${BOLD}LOCAL REPOS (clone mode only):${RESET}"
	echo "    Repositories are cloned to:"
	echo "        ~/Repositories/go/src/github.com/<org>/<repo>"
	echo "    Existing clones are updated with git fetch/pull."
	echo "    Clones persist between runs for faster subsequent scans."
	echo
	echo -e "${BOLD}EXAMPLES:${RESET}"
	echo "    # Run with clone mode (default, fastest for local use)"
	echo "    ./$(basename "$0")"
	echo
	echo "    # Run with API mode (for GitHub Actions, no cloning)"
	echo "    ./$(basename "$0") --mode api"
	echo
	echo "    # Force refresh, ignoring cache"
	echo "    ./$(basename "$0") --force"
	echo
	echo "    # Scan without updating tracking issue"
	echo "    ./$(basename "$0") --no-tracking"
	echo
	exit 0
}

# Feature flags
FORCE_REFRESH=false
UPDATE_TRACKING=true
SCAN_MODE="clone" # "clone" or "api"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
	case $1 in
	-h | --help)
		show_help
		;;
	-f | --force)
		FORCE_REFRESH=true
		;;
	--no-tracking)
		UPDATE_TRACKING=false
		;;
	--mode)
		if [ -z "$2" ] || [[ "$2" == -* ]]; then
			echo -e "${RED}ERROR: --mode requires an argument (api or clone)${RESET}"
			exit 1
		fi
		if [[ "$2" != "api" && "$2" != "clone" ]]; then
			echo -e "${RED}ERROR: --mode must be 'api' or 'clone'${RESET}"
			exit 1
		fi
		SCAN_MODE="$2"
		shift
		;;
	*)
		echo -e "${RED}Unknown option: $1${RESET}"
		echo "Use -h or --help for usage information"
		exit 1
		;;
	esac
	shift
done

# Check if GitHub CLI is installed
echo "Checking GitHub CLI installation..."
if ! command -v gh &>/dev/null; then
	echo -e "${RED}ERROR: GitHub CLI (gh) is not installed!${RESET}"
	echo -e "${YELLOW}Please install it first:${RESET}"
	echo -e "${YELLOW}   macOS: brew install gh${RESET}"
	echo -e "${YELLOW}   Linux: https://github.com/cli/cli/blob/trunk/docs/install_linux.md${RESET}"
	echo -e "${YELLOW}   Or visit: https://cli.github.com/${RESET}"
	exit 1
fi
echo -e "${GREEN}GitHub CLI is installed${RESET}"

# Check if GitHub CLI is logged in
echo "Checking GitHub CLI authentication..."
if ! gh auth status &>/dev/null; then
	echo -e "${RED}ERROR: GitHub CLI is not logged in!${RESET}"
	echo -e "${YELLOW}Please run 'gh auth login' to authenticate first.${RESET}"
	exit 1
fi
echo -e "${GREEN}GitHub CLI authenticated successfully${RESET}"

# Check if git is installed (only needed for clone mode)
if [ "$SCAN_MODE" = "clone" ]; then
	echo "Checking git installation..."
	if ! command -v git &>/dev/null; then
		echo -e "${RED}ERROR: git is not installed!${RESET}"
		echo -e "${YELLOW}Please install git first${RESET}"
		exit 1
	fi
	echo -e "${GREEN}git is installed${RESET}"
fi

# Check if jq is installed
echo "Checking jq installation..."
if ! command -v jq &>/dev/null; then
	echo -e "${RED}ERROR: jq is not installed!${RESET}"
	echo -e "${YELLOW}Please install it first:${RESET}"
	echo -e "${YELLOW}   macOS: brew install jq${RESET}"
	echo -e "${YELLOW}   Linux: apt-get install jq${RESET}"
	exit 1
fi
echo -e "${GREEN}jq is installed${RESET}"
echo

# List of orgs to scan (can be overridden by environment variable)
if [ -z "${ORGS+x}" ]; then
	ORGS=("redhat-best-practices-for-k8s" "openshift" "openshift-kni" "redhat-openshift-ecosystem" "redhatci")
fi

LIMIT=1000
TOTAL_REPOS=0
SKIPPED_FORKS=0
SKIPPED_NOGOMOD=0
SKIPPED_ABANDONED=0
SKIPPED_BLOCKLIST=0
CLONE_FAILURES=0

# Severity counters
CRITICAL_COUNT=0
HIGH_COUNT=0
MEDIUM_COUNT=0
INFO_COUNT=0

# Get script directory for relative paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Shared cache files (used by all lookup scripts)
CACHE_DIR="$SCRIPT_DIR/caches"
FORK_CACHE="$CACHE_DIR/forks.txt"
NOGOMOD_CACHE="$CACHE_DIR/no-gomod.txt"
ABANDONED_CACHE="$CACHE_DIR/abandoned.txt"
BLOCKLIST_FILE="$SCRIPT_DIR/tls13-repo-blocklist.txt"
OUTPUT_MD="tls13-compliance-report.md"

# Script-specific results cache
RESULTS_CACHE=".tls13-checker-results.json"

# Local repos directory (persistent)
LOCAL_REPOS_DIR="$HOME/Repositories/go/src/github.com"

# Ensure directories exist
mkdir -p "$CACHE_DIR"
if [ "$SCAN_MODE" = "clone" ]; then
	mkdir -p "$LOCAL_REPOS_DIR"
fi

# Inactivity threshold (in days)
INACTIVITY_DAYS=180 # 6 months

# Cache age threshold (in seconds) - 6 hours
CACHE_MAX_AGE=$((6 * 60 * 60))

# Create empty cache files if they don't exist
touch "$FORK_CACHE" "$NOGOMOD_CACHE" "$ABANDONED_CACHE"

# Tracking issue configuration
TRACKING_REPO="redhat-best-practices-for-k8s/telco-bot"
TRACKING_ISSUE_TITLE="Tracking TLS Configuration Compliance"

# TLS patterns to search for
# Format: "severity|pattern_name|description|regex"
TLS_PATTERNS=(
	"CRITICAL|InsecureSkipVerify: true|Disables TLS certificate verification (MITM vulnerability)|InsecureSkipVerify[[:space:]]*:[[:space:]]*true"
	"HIGH|MinVersion TLS 1.0|TLS 1.0 has known vulnerabilities (POODLE, BEAST)|MinVersion[[:space:]]*[:=][[:space:]]*.*VersionTLS10"
	"HIGH|MinVersion TLS 1.1|TLS 1.1 has known vulnerabilities|MinVersion[[:space:]]*[:=][[:space:]]*.*VersionTLS11"
	"HIGH|MaxVersion TLS 1.0|Limits connections to weak TLS 1.0|MaxVersion[[:space:]]*[:=][[:space:]]*.*VersionTLS10"
	"HIGH|MaxVersion TLS 1.1|Limits connections to weak TLS 1.1|MaxVersion[[:space:]]*[:=][[:space:]]*.*VersionTLS11"
	"MEDIUM|MaxVersion TLS 1.2|Prevents TLS 1.3 negotiation|MaxVersion[[:space:]]*[:=][[:space:]]*.*VersionTLS12"
	"INFO|MinVersion TLS 1.3|Forces TLS 1.3 (may break older clients)|MinVersion[[:space:]]*[:=][[:space:]]*.*VersionTLS13"
	"INFO|PreferServerCipherSuites|Deprecated in Go 1.17+ (ignored)|PreferServerCipherSuites[[:space:]]*:[[:space:]]*true"
)

#===============================================================================
# HELPER FUNCTIONS
#===============================================================================

# Helper function to check if repo is in cache
is_in_cache() {
	local repo="$1"
	local cache_file="$2"
	grep -Fxq "$repo" "$cache_file" 2>/dev/null
}

# Helper function to check if repo is in blocklist
is_blocklisted() {
	local repo="$1"

	if [ ! -f "$BLOCKLIST_FILE" ]; then
		return 1
	fi

	# Normalize and check against blocklist
	while IFS= read -r line || [ -n "$line" ]; do
		# Skip empty lines and comments
		[[ -z "$line" || "$line" =~ ^[[:space:]]*(#|//) ]] && continue

		# Normalize the line (remove github.com prefix, https, etc.)
		local normalized=$(echo "$line" | sed -e 's|https://github.com/||' -e 's|github.com/||' -e 's|^[[:space:]]*||' -e 's|[[:space:]]*$||')

		if [ "$normalized" = "$repo" ]; then
			return 0
		fi
	done <"$BLOCKLIST_FILE"

	return 1
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

# Helper function to check if repo is abandoned (no commits in last 6 months)
is_repo_abandoned() {
	local repo="$1"
	local branch="$2"

	# Calculate cutoff date
	local cutoff_date=$(date -u -v-${INACTIVITY_DAYS}d "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "${INACTIVITY_DAYS} days ago" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)

	if [ -z "$cutoff_date" ]; then
		return 1
	fi

	# Fetch last commit date from default branch
	local last_commit=$(gh api "repos/${repo}/commits/${branch}" --jq '.commit.committer.date' 2>/dev/null)

	if [[ $? -ne 0 || -z "$last_commit" ]]; then
		return 1
	fi

	# Compare dates
	if [ "$last_commit" \< "$cutoff_date" ]; then
		return 0
	else
		return 1
	fi
}

# Helper function to ensure repo is cloned and up-to-date
ensure_repo_updated() {
	local repo="$1"
	local branch="$2"
	local org="${repo%%/*}"
	local repo_name="${repo##*/}"
	local repo_path="$LOCAL_REPOS_DIR/$org/$repo_name"

	# Ensure org directory exists
	mkdir -p "$LOCAL_REPOS_DIR/$org"

	if [ -d "$repo_path/.git" ]; then
		# Repo exists - update to latest
		(
			cd "$repo_path" &&
				git fetch -q origin 2>/dev/null &&
				git checkout -q "$branch" 2>/dev/null &&
				git pull -q origin "$branch" 2>/dev/null
		)
		if [ $? -eq 0 ]; then
			echo "$repo_path"
			return 0
		else
			# Try resetting if pull failed
			(
				cd "$repo_path" &&
					git reset --hard "origin/$branch" 2>/dev/null
			)
			if [ $? -eq 0 ]; then
				echo "$repo_path"
				return 0
			fi
		fi
	fi

	# Repo doesn't exist or update failed - try to clone
	if [ ! -d "$repo_path/.git" ]; then
		git clone -q --depth 1 --branch "$branch" "https://github.com/$repo.git" "$repo_path" 2>/dev/null
		if [ $? -eq 0 ]; then
			echo "$repo_path"
			return 0
		fi
	fi

	# Clone failed
	return 1
}

# Helper function to scan local repo for TLS patterns
scan_local_repo() {
	local repo_path="$1"
	local branch="$2"
	local findings="[]"

	for pattern_def in "${TLS_PATTERNS[@]}"; do
		IFS='|' read -r severity pattern description regex <<<"$pattern_def"

		# Search for pattern, excluding vendor, testdata, mocks, test directories, and test files
		local matches=$(grep -rn --include="*.go" -E "$regex" "$repo_path" \
			--exclude-dir=vendor --exclude-dir=testdata --exclude-dir=mocks \
			--exclude-dir=.git --exclude-dir=test --exclude-dir=tests \
			--exclude-dir=e2e --exclude-dir=testing --exclude-dir=mock \
			--exclude-dir=fakes --exclude-dir=fixtures \
			--exclude="*_test.go" 2>/dev/null)

		if [ -n "$matches" ]; then
			# Extract file paths (relative to repo) and count
			local files=$(echo "$matches" | cut -d: -f1 | sort -u | sed "s|$repo_path/||g" | tr '\n' ',' | sed 's/,$//')
			local count=$(echo "$matches" | wc -l | tr -d ' ')

			# Add to findings using jq (include branch for hyperlinks)
			findings=$(echo "$findings" | jq --arg s "$severity" --arg p "$pattern" \
				--arg d "$description" --arg f "$files" --arg c "$count" --arg b "$branch" \
				'. + [{severity: $s, pattern: $p, description: $d, files: $f, count: ($c|tonumber), branch: $b}]')
		fi
	done

	echo "$findings"
}

# Helper function to update results cache
update_cache_result() {
	local repo="$1"
	local findings="$2"
	local branch="$3"

	local timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

	# Create cache file if it doesn't exist
	if [ ! -f "$RESULTS_CACHE" ]; then
		echo '{"timestamp":"'"$timestamp"'","repositories":{}}' >"$RESULTS_CACHE"
	fi

	# Update the cache (include branch for hyperlinks)
	local temp_cache=$(mktemp)
	jq --arg repo "$repo" --argjson findings "$findings" --arg timestamp "$timestamp" --arg branch "$branch" \
		'.repositories[$repo] = {findings: $findings, last_checked: $timestamp, branch: $branch}' "$RESULTS_CACHE" >"$temp_cache" 2>/dev/null && mv "$temp_cache" "$RESULTS_CACHE" || rm -f "$temp_cache"
}

# Helper function to get cached result for a repository
get_cached_result() {
	local repo="$1"

	if [ ! -f "$RESULTS_CACHE" ]; then
		echo "null"
		return
	fi

	local result=$(jq -r ".repositories[\"$repo\"] // null" "$RESULTS_CACHE" 2>/dev/null)
	echo "$result"
}

# Helper function to update cache timestamp
update_cache_timestamp() {
	local timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

	if [ -f "$RESULTS_CACHE" ]; then
		local temp_cache=$(mktemp)
		jq ".timestamp = \"$timestamp\"" "$RESULTS_CACHE" >"$temp_cache" 2>/dev/null && mv "$temp_cache" "$RESULTS_CACHE" || rm -f "$temp_cache"
	fi
}

#===============================================================================
# API-BASED SCANNING (for GitHub Actions / no-clone mode)
#===============================================================================

# API-friendly search patterns for GitHub Code Search
# Format: "severity|pattern_name|description|search_query|verify_regex"
# Note: GitHub Code Search doesn't support full regex, so we use simple keywords
# and verify matches by fetching file content
API_PATTERNS=(
	"CRITICAL|InsecureSkipVerify: true|Disables TLS certificate verification (MITM vulnerability)|InsecureSkipVerify true|InsecureSkipVerify[[:space:]]*:[[:space:]]*true"
	"HIGH|MinVersion TLS 1.0|TLS 1.0 has known vulnerabilities (POODLE, BEAST)|MinVersion VersionTLS10|MinVersion.*VersionTLS10"
	"HIGH|MinVersion TLS 1.1|TLS 1.1 has known vulnerabilities|MinVersion VersionTLS11|MinVersion.*VersionTLS11"
	"HIGH|MaxVersion TLS 1.0|Limits connections to weak TLS 1.0|MaxVersion VersionTLS10|MaxVersion.*VersionTLS10"
	"HIGH|MaxVersion TLS 1.1|Limits connections to weak TLS 1.1|MaxVersion VersionTLS11|MaxVersion.*VersionTLS11"
	"MEDIUM|MaxVersion TLS 1.2|Prevents TLS 1.3 negotiation|MaxVersion VersionTLS12|MaxVersion.*VersionTLS12"
	"INFO|MinVersion TLS 1.3|Forces TLS 1.3 (may break older clients)|MinVersion VersionTLS13|MinVersion.*VersionTLS13"
	"INFO|PreferServerCipherSuites|Deprecated in Go 1.17+ (ignored)|PreferServerCipherSuites true|PreferServerCipherSuites[[:space:]]*:[[:space:]]*true"
)

# Rate limiting for API mode (requests per minute limit)
API_DELAY=7 # seconds between code search requests (to stay under 10/min)
LAST_API_CALL=0

# Helper function to respect API rate limits
api_rate_limit() {
	local now=$(date +%s)
	local elapsed=$((now - LAST_API_CALL))
	if [ $elapsed -lt $API_DELAY ]; then
		sleep $((API_DELAY - elapsed))
	fi
	LAST_API_CALL=$(date +%s)
}

# Helper function to check if a file path should be excluded
should_exclude_path() {
	local filepath="$1"

	# Exclude vendor, test directories, and test files
	case "$filepath" in
	vendor/* | */vendor/*) return 0 ;;
	testdata/* | */testdata/*) return 0 ;;
	mocks/* | */mocks/*) return 0 ;;
	mock/* | */mock/*) return 0 ;;
	test/* | */test/*) return 0 ;;
	tests/* | */tests/*) return 0 ;;
	e2e/* | */e2e/*) return 0 ;;
	testing/* | */testing/*) return 0 ;;
	fakes/* | */fakes/*) return 0 ;;
	fixtures/* | */fixtures/*) return 0 ;;
	*_test.go) return 0 ;;
	esac

	return 1
}

# Helper function to verify a match by fetching file content
verify_match_in_file() {
	local repo="$1"
	local branch="$2"
	local filepath="$3"
	local verify_regex="$4"

	# Fetch file content with timeout and retry
	local raw_url="https://raw.githubusercontent.com/$repo/$branch/$filepath"
	local content=""
	local retries=2

	for ((i = 1; i <= retries; i++)); do
		content=$(curl -s -f --max-time 30 "$raw_url" 2>/dev/null)
		if [ -n "$content" ]; then
			break
		fi
		sleep 1
	done

	if [ -z "$content" ]; then
		return 1
	fi

	# Check if the regex matches
	if echo "$content" | grep -qE "$verify_regex"; then
		return 0
	fi

	return 1
}

# Helper function to scan a single repo using GitHub Code Search API
scan_repo_api() {
	local repo="$1"
	local branch="$2"
	local findings="[]"

	for pattern_def in "${API_PATTERNS[@]}"; do
		IFS='|' read -r severity pattern description search_query verify_regex <<<"$pattern_def"

		# Rate limit
		api_rate_limit

		# Build full query with exclusions
		# GitHub Code Search supports NOT path: syntax in the query string
		# Note: We exclude common test/vendor directories directly in the search
		local full_query="${search_query} NOT path:vendor/ NOT path:testdata/ NOT path:mocks/ NOT path:mock/ NOT path:test/ NOT path:tests/ NOT path:e2e/ NOT path:testing/ NOT path:fakes/ NOT path:fixtures/"

		# Search using gh search code with exclusions in the query
		local search_result=$(gh search code "$full_query" \
			--repo "$repo" \
			--extension go \
			--limit 100 \
			--json path 2>/dev/null)

		if [ -z "$search_result" ] || [ "$search_result" = "[]" ] || [ "$search_result" = "null" ]; then
			continue
		fi

		# Extract unique file paths
		local file_paths=$(echo "$search_result" | jq -r '.[].path' 2>/dev/null | sort -u)

		if [ -z "$file_paths" ]; then
			continue
		fi

		# Filter and verify matches
		local verified_files=""
		local verified_count=0

		while IFS= read -r filepath; do
			[ -z "$filepath" ] && continue

			# Double-check exclusions (in case API didn't filter properly)
			if should_exclude_path "$filepath"; then
				continue
			fi

			# Verify the match by fetching file content
			if verify_match_in_file "$repo" "$branch" "$filepath" "$verify_regex"; then
				if [ -n "$verified_files" ]; then
					verified_files="$verified_files,$filepath"
				else
					verified_files="$filepath"
				fi
				verified_count=$((verified_count + 1))
			fi
		done <<<"$file_paths"

		# Add verified findings
		if [ $verified_count -gt 0 ]; then
			findings=$(echo "$findings" | jq --arg s "$severity" --arg p "$pattern" \
				--arg d "$description" --arg f "$verified_files" --arg c "$verified_count" --arg b "$branch" \
				'. + [{severity: $s, pattern: $p, description: $d, files: $f, count: ($c|tonumber), branch: $b}]')
		fi
	done

	echo "$findings"
}

#===============================================================================
# LOAD CACHES
#===============================================================================

# Load fork cache info if it exists
FORK_COUNT_LOADED=0
if [ -f "$FORK_CACHE" ] && [ -s "$FORK_CACHE" ]; then
	FORK_COUNT_LOADED=$(wc -l <"$FORK_CACHE" | tr -d ' ')
	echo "Loading fork cache from $FORK_CACHE..."
	echo -e "${GREEN}Loaded ${FORK_COUNT_LOADED} fork repositories to skip${RESET}"
	echo
fi

# Load no-go.mod cache info if it exists
NOGOMOD_COUNT_LOADED=0
if [ -f "$NOGOMOD_CACHE" ] && [ -s "$NOGOMOD_CACHE" ]; then
	NOGOMOD_COUNT_LOADED=$(wc -l <"$NOGOMOD_CACHE" | tr -d ' ')
	echo "Loading no-go.mod cache from $NOGOMOD_CACHE..."
	echo -e "${GREEN}Loaded ${NOGOMOD_COUNT_LOADED} repositories without go.mod to skip${RESET}"
	echo
fi

# Load abandoned repo cache info if it exists
ABANDONED_COUNT_LOADED=0
if [ -f "$ABANDONED_CACHE" ] && [ -s "$ABANDONED_CACHE" ]; then
	ABANDONED_COUNT_LOADED=$(wc -l <"$ABANDONED_CACHE" | tr -d ' ')
	echo "Loading abandoned repo cache from $ABANDONED_CACHE..."
	echo -e "${GREEN}Loaded ${ABANDONED_COUNT_LOADED} abandoned repositories to skip${RESET}"
	echo
fi

# Check results cache validity
CACHE_VALID=false
if is_cache_valid; then
	CACHE_VALID=true
	CACHED_REPO_COUNT=$(jq '.repositories | length' "$RESULTS_CACHE" 2>/dev/null || echo "0")
	CACHE_TIMESTAMP=$(jq -r '.timestamp' "$RESULTS_CACHE" 2>/dev/null || echo "unknown")
	echo "Loading results cache from $RESULTS_CACHE..."
	echo -e "${GREEN}Cache is valid (age < 6 hours)${RESET}"
	echo -e "${GREEN}Loaded ${CACHED_REPO_COUNT} cached results from ${CACHE_TIMESTAMP}${RESET}"
	echo
else
	if [ -f "$RESULTS_CACHE" ]; then
		if [ "$FORCE_REFRESH" = true ]; then
			echo "Results cache exists but --force flag set, ignoring cache..."
		else
			echo "Results cache is stale (age > 6 hours), will refresh..."
		fi
	else
		echo "No results cache found, will scan all repositories..."
	fi
	echo
fi

# Display mode information
if [ "$SCAN_MODE" = "clone" ]; then
	echo -e "${BLUE}Scan mode: clone (using local repositories)${RESET}"
	echo -e "${BLUE}Local repos directory: ${LOCAL_REPOS_DIR}${RESET}"
else
	echo -e "${BLUE}Scan mode: api (using GitHub Code Search API)${RESET}"
	echo -e "${YELLOW}Note: API mode has rate limits (~10 searches/min) and may take longer${RESET}"
fi
echo

# Temporary file to track newly discovered no-go.mod repos
NOGOMOD_TEMP=$(mktemp)

# Temporary file to store org-specific data for tracking issue
ORG_DATA_FILE=$(mktemp)

# Temporary file to track per-org statistics (bash 3.x compatible)
ORG_STATS_FILE=$(mktemp)

# Arrays to store findings by severity
declare -a CRITICAL_FINDINGS
declare -a HIGH_FINDINGS
declare -a MEDIUM_FINDINGS
declare -a INFO_FINDINGS

echo -e "${BLUE}${BOLD}SCANNING REPOSITORIES FOR TLS CONFIGURATION ISSUES${RESET}"
echo -e "${BLUE}=======================================================${RESET}"
echo -e "${YELLOW}Checking for: InsecureSkipVerify, weak TLS versions,${RESET}"
echo -e "${YELLOW}              MaxVersion caps, and deprecated options${RESET}"
echo -e "${BLUE}-------------------------------------------------------${RESET}"
echo

for ORG_NAME in "${ORGS[@]}"; do
	echo -e "${YELLOW}${BOLD}Organization: ${ORG_NAME}${RESET}"

	# Get all repos (Go language, non-archived, non-fork)
	echo -e "${BLUE}   Fetching repository list...${RESET}"
	REPOS=$(gh repo list "$ORG_NAME" --limit "$LIMIT" --json nameWithOwner,defaultBranchRef,isArchived,primaryLanguage,isFork -q '.[] | select(.isArchived == false) | select(.primaryLanguage.name == "Go") | .nameWithOwner + " " + .defaultBranchRef.name + " " + (.isFork | tostring)')
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
	ORG_CRITICAL=0
	ORG_HIGH=0
	ORG_MEDIUM=0
	ORG_INFO=0

	while read -r repo branch is_fork; do
		# Skip empty lines
		[[ -z "$repo" ]] && continue

		# Show progress indicator
		echo -ne "   ${repo} on branch ${branch}... "

		# Check if repo is blocklisted
		if is_blocklisted "$repo"; then
			echo -e "${BLUE}skipped (blocklisted)${RESET}"
			SKIPPED_BLOCKLIST=$((SKIPPED_BLOCKLIST + 1))
			continue
		fi

		# Check if repo is a fork (either from cache or API)
		if is_in_cache "$repo" "$FORK_CACHE" || [ "$is_fork" = "true" ]; then
			echo -e "${BLUE}skipped (fork)${RESET}"
			SKIPPED_FORKS=$((SKIPPED_FORKS + 1))
			if [ "$is_fork" = "true" ] && ! is_in_cache "$repo" "$FORK_CACHE"; then
				echo "$repo" >>"$FORK_CACHE"
			fi
			continue
		fi

		# Check if repo is in abandoned cache
		if is_in_cache "$repo" "$ABANDONED_CACHE"; then
			echo -e "${BLUE}skipped (abandoned)${RESET}"
			SKIPPED_ABANDONED=$((SKIPPED_ABANDONED + 1))
			continue
		fi

		# Check if repo is abandoned (no commits in last 6 months)
		if is_repo_abandoned "$repo" "$branch"; then
			echo -e "${BLUE}skipped (abandoned - no recent commits)${RESET}"
			echo "$repo" >>"$ABANDONED_CACHE"
			SKIPPED_ABANDONED=$((SKIPPED_ABANDONED + 1))
			continue
		fi

		# Check if repo is in no-go.mod cache
		if is_in_cache "$repo" "$NOGOMOD_CACHE"; then
			echo -e "${BLUE}skipped (no go.mod)${RESET}"
			SKIPPED_NOGOMOD=$((SKIPPED_NOGOMOD + 1))
			continue
		fi

		# Check for go.mod via API (faster than cloning first)
		raw_url="https://raw.githubusercontent.com/$repo/$branch/go.mod"
		if ! curl -s -f -I "$raw_url" >/dev/null 2>&1; then
			echo -e "${YELLOW}no go.mod (cached)${RESET}"
			echo "$repo" >>"$NOGOMOD_TEMP"
			SKIPPED_NOGOMOD=$((SKIPPED_NOGOMOD + 1))
			continue
		fi

		# Check results cache first
		if [ "$CACHE_VALID" = true ]; then
			cached_result=$(get_cached_result "$repo")
			if [ "$cached_result" != "null" ]; then
				# Parse cached findings
				cached_findings=$(echo "$cached_result" | jq '.findings')
				if [ "$cached_findings" != "null" ] && [ "$cached_findings" != "[]" ]; then
					echo -e "${YELLOW}issues found (cached)${RESET}"

					# Count by severity from cache
					for severity in CRITICAL HIGH MEDIUM INFO; do
						count=$(echo "$cached_findings" | jq "[.[] | select(.severity == \"$severity\")] | length")
						case $severity in
						CRITICAL) ORG_CRITICAL=$((ORG_CRITICAL + count)) ;;
						HIGH) ORG_HIGH=$((ORG_HIGH + count)) ;;
						MEDIUM) ORG_MEDIUM=$((ORG_MEDIUM + count)) ;;
						INFO) ORG_INFO=$((ORG_INFO + count)) ;;
						esac
					done

					# Store for report
					echo "$ORG_NAME|$repo|$branch|$cached_findings" >>"$ORG_DATA_FILE"
					continue
				elif [ "$cached_findings" = "[]" ]; then
					echo -e "${GREEN}no issues (cached)${RESET}"
					continue
				fi
			fi
		fi

		# Perform scanning based on mode
		if [ "$SCAN_MODE" = "api" ]; then
			# API mode: use GitHub Code Search
			findings=$(scan_repo_api "$repo" "$branch")
		else
			# Clone mode: ensure repo is cloned and up-to-date
			repo_path=$(ensure_repo_updated "$repo" "$branch")
			if [ -z "$repo_path" ] || [ ! -d "$repo_path" ]; then
				echo -e "${RED}clone failed${RESET}"
				CLONE_FAILURES=$((CLONE_FAILURES + 1))
				continue
			fi

			# Perform TLS pattern search using grep
			findings=$(scan_local_repo "$repo_path" "$branch")
		fi

		if [ -z "$findings" ] || [ "$findings" = "[]" ] || [ "$findings" = "null" ]; then
			echo -e "${GREEN}no issues found${RESET}"
			update_cache_result "$repo" "[]" "$branch"
		else
			finding_count=$(echo "$findings" | jq 'length')
			echo -e "${YELLOW}${finding_count} issue(s) found${RESET}"

			# Update cache
			update_cache_result "$repo" "$findings" "$branch"

			# Count by severity
			for severity in CRITICAL HIGH MEDIUM INFO; do
				count=$(echo "$findings" | jq "[.[] | select(.severity == \"$severity\")] | length")
				case $severity in
				CRITICAL) ORG_CRITICAL=$((ORG_CRITICAL + count)) ;;
				HIGH) ORG_HIGH=$((ORG_HIGH + count)) ;;
				MEDIUM) ORG_MEDIUM=$((ORG_MEDIUM + count)) ;;
				INFO) ORG_INFO=$((ORG_INFO + count)) ;;
				esac
			done

			# Store for report
			echo "$ORG_NAME|$repo|$branch|$findings" >>"$ORG_DATA_FILE"
		fi

	done <<<"$REPOS"

	# Update global counters
	CRITICAL_COUNT=$((CRITICAL_COUNT + ORG_CRITICAL))
	HIGH_COUNT=$((HIGH_COUNT + ORG_HIGH))
	MEDIUM_COUNT=$((MEDIUM_COUNT + ORG_MEDIUM))
	INFO_COUNT=$((INFO_COUNT + ORG_INFO))

	# Track total issues for this org and save to stats file
	ORG_TOTAL_ISSUES=$((ORG_CRITICAL + ORG_HIGH + ORG_MEDIUM + ORG_INFO))
	echo "${ORG_NAME}|${REPO_COUNT}|${ORG_TOTAL_ISSUES}" >>"$ORG_STATS_FILE"

	# Summary for this organization
	echo
	echo -e "${YELLOW}${BOLD}Summary for ${ORG_NAME}:${RESET}"
	echo -e "   ${RED}CRITICAL: ${ORG_CRITICAL}${RESET} | ${YELLOW}HIGH: ${ORG_HIGH}${RESET} | ${BLUE}MEDIUM: ${ORG_MEDIUM}${RESET} | INFO: ${ORG_INFO}"
	echo -e "${BLUE}-------------------------------------------------------${RESET}"
	echo
done

# Update no-go.mod cache
if [ -f "$NOGOMOD_TEMP" ] && [ -s "$NOGOMOD_TEMP" ]; then
	cat "$NOGOMOD_TEMP" >>"$NOGOMOD_CACHE"
	sort -u "$NOGOMOD_CACHE" -o "$NOGOMOD_CACHE"
	NEW_NOGOMOD=$(wc -l <"$NOGOMOD_TEMP" | tr -d ' ')
	echo -e "${BLUE}Updated no-go.mod cache with ${NEW_NOGOMOD} new entries${RESET}"
	echo
fi
rm -f "$NOGOMOD_TEMP"

# Sort and deduplicate caches
if [ -f "$FORK_CACHE" ] && [ -s "$FORK_CACHE" ]; then
	sort -u "$FORK_CACHE" -o "$FORK_CACHE"
fi

if [ -f "$ABANDONED_CACHE" ] && [ -s "$ABANDONED_CACHE" ]; then
	sort -u "$ABANDONED_CACHE" -o "$ABANDONED_CACHE"
fi

# Calculate totals
TOTAL_ISSUES=$((CRITICAL_COUNT + HIGH_COUNT + MEDIUM_COUNT + INFO_COUNT))
REPOS_WITH_ISSUES=$(wc -l <"$ORG_DATA_FILE" 2>/dev/null | tr -d ' ')
REPOS_WITH_ISSUES=${REPOS_WITH_ISSUES:-0}

# Final summary
echo -e "${BOLD}${BLUE}FINAL RESULTS:${RESET}"
echo -e "${BOLD}   Total repositories scanned:${RESET} ${TOTAL_REPOS}"
echo -e "${BOLD}   Repositories skipped (forks):${RESET} ${BLUE}${SKIPPED_FORKS}${RESET}"
echo -e "${BOLD}   Repositories skipped (abandoned):${RESET} ${BLUE}${SKIPPED_ABANDONED}${RESET}"
echo -e "${BOLD}   Repositories skipped (no go.mod):${RESET} ${BLUE}${SKIPPED_NOGOMOD}${RESET}"
echo -e "${BOLD}   Repositories skipped (blocklisted):${RESET} ${BLUE}${SKIPPED_BLOCKLIST}${RESET}"
if [ "$SCAN_MODE" = "clone" ] && [ "$CLONE_FAILURES" -gt 0 ]; then
	echo -e "${BOLD}   Clone failures:${RESET} ${RED}${CLONE_FAILURES}${RESET}"
fi
echo -e "${BOLD}   Scan mode:${RESET} ${SCAN_MODE}"
echo -e "${BOLD}   Repositories with issues:${RESET} ${YELLOW}${REPOS_WITH_ISSUES}${RESET}"
echo
echo -e "${BOLD}${BLUE}FINDINGS BY SEVERITY:${RESET}"
echo -e "   ${RED}CRITICAL:${RESET} ${CRITICAL_COUNT}"
echo -e "   ${YELLOW}HIGH:${RESET} ${HIGH_COUNT}"
echo -e "   ${BLUE}MEDIUM:${RESET} ${MEDIUM_COUNT}"
echo -e "   INFO: ${INFO_COUNT}"
echo

#===============================================================================
# GENERATE MARKDOWN REPORT
#===============================================================================

echo "Generating markdown report: $OUTPUT_MD"
{
	echo "# TLS Configuration Compliance Report"
	echo ""
	echo "**Generated:** $(date '+%Y-%m-%d %H:%M:%S %Z')"
	echo ""
	echo "## Summary"
	echo ""
	echo "- **Total repositories scanned:** ${TOTAL_REPOS}"
	echo "- **Repositories with issues:** ${REPOS_WITH_ISSUES}"
	echo "- **Critical issues:** ${CRITICAL_COUNT}"
	echo "- **High issues:** ${HIGH_COUNT}"
	echo "- **Medium issues:** ${MEDIUM_COUNT}"
	echo "- **Info issues:** ${INFO_COUNT}"
	echo ""
	echo "## Severity Levels"
	echo ""
	echo "| Severity | Description |"
	echo "|----------|-------------|"
	echo "| CRITICAL | InsecureSkipVerify: true - Disables certificate verification, enables MITM attacks |"
	echo "| HIGH | TLS 1.0/1.1 MinVersion or MaxVersion - Known vulnerabilities (POODLE, BEAST) |"
	echo "| MEDIUM | MaxVersion capped at TLS 1.2 - Prevents TLS 1.3 negotiation |"
	echo "| INFO | Forced TLS 1.3, or PreferServerCipherSuites (deprecated in Go 1.17+) |"
	echo ""

	if [ "$REPOS_WITH_ISSUES" -gt 0 ]; then
		echo "## Findings by Organization"
		echo ""

		# Create temp jq file for reliable query execution (with file hyperlinks)
		JQ_MD_TABLE=$(mktemp)
		cat >"$JQ_MD_TABLE" <<'JQEOF'
.repositories | to_entries | map(select(.value.findings | length > 0)) | map(select(.key | startswith($org + "/"))) | .[] | .key as $repo | .value.branch as $branch | .value.findings[] | select(.severity == $sev) |
  # Build file link - show first file as hyperlink, add count if more
  (.files | split(",") | .[0]) as $first_file |
  (.files | split(",") | length) as $file_count |
  ($first_file | split("/") | last) as $filename |
  (if $file_count > 1 then "[`" + $filename + "`](https://github.com/" + $repo + "/blob/" + $branch + "/" + $first_file + ") (+" + (($file_count - 1) | tostring) + " more)" else "[`" + $filename + "`](https://github.com/" + $repo + "/blob/" + $branch + "/" + $first_file + ")" end) as $file_link |
  "| [`" + ($repo | split("/") | last) + "`](https://github.com/" + $repo + ") | " + .pattern + " | " + $file_link + " | " + .description + " |"
JQEOF

		# Get unique orgs that have findings
		ORGS_WITH_FINDINGS=$(jq -r '.repositories | to_entries | map(select(.value.findings | length > 0)) | .[].key | split("/")[0]' "$RESULTS_CACHE" 2>/dev/null | sort -u)

		for org in $ORGS_WITH_FINDINGS; do
			# Count total issues for this org
			org_issue_count=$(jq -r --arg org "$org" '[.repositories | to_entries | map(select(.key | startswith($org + "/"))) | .[].value.findings[]?] | length' "$RESULTS_CACHE" 2>/dev/null)

			echo "### Organization: ${org} (${org_issue_count} issues)"
			echo ""

			# Group by severity within this org
			for severity in CRITICAL HIGH MEDIUM INFO; do
				# Check if there are findings for this severity in this org
				severity_count=$(jq -r --arg sev "$severity" --arg org "$org" '[.repositories | to_entries | map(select(.key | startswith($org + "/"))) | .[].value.findings[]? | select(.severity == $sev)] | length' "$RESULTS_CACHE" 2>/dev/null)

				if [ "$severity_count" -gt 0 ]; then
					echo "#### ${severity} (${severity_count})"
					echo ""
					echo "| Repository | Pattern | Files | Description |"
					echo "|------------|---------|-------|-------------|"

					jq -r --arg sev "$severity" --arg org "$org" -f "$JQ_MD_TABLE" "$RESULTS_CACHE" 2>/dev/null

					echo ""
				fi
			done
		done

		rm -f "$JQ_MD_TABLE"

		echo "## Remediation Guide"
		echo ""
		echo "### Critical: InsecureSkipVerify"
		echo ""
		echo "**Never** set \`InsecureSkipVerify: true\` in production code. This disables TLS certificate verification and makes the connection vulnerable to man-in-the-middle attacks."
		echo ""
		echo "\`\`\`go"
		echo "// BAD - DO NOT USE IN PRODUCTION"
		echo "tlsConfig := &tls.Config{"
		echo "    InsecureSkipVerify: true, // VULNERABLE"
		echo "}"
		echo ""
		echo "// GOOD - Verify certificates properly"
		echo "tlsConfig := &tls.Config{"
		echo "    // Use system root CA pool by default"
		echo "    // Or specify custom CA if needed"
		echo "    RootCAs: customCertPool,"
		echo "}"
		echo "\`\`\`"
		echo ""
		echo "### High: Weak TLS Versions"
		echo ""
		echo "TLS 1.0 and 1.1 have known vulnerabilities (POODLE, BEAST) and should not be used."
		echo ""
		echo "\`\`\`go"
		echo "// BAD"
		echo "tlsConfig := &tls.Config{"
		echo "    MinVersion: tls.VersionTLS10, // VULNERABLE"
		echo "}"
		echo ""
		echo "// GOOD - Use TLS 1.2 minimum, prefer 1.3"
		echo "tlsConfig := &tls.Config{"
		echo "    MinVersion: tls.VersionTLS12,"
		echo "}"
		echo "\`\`\`"
		echo ""
		echo "### Medium: TLS 1.2 Cap"
		echo ""
		echo "Capping MaxVersion at TLS 1.2 prevents TLS 1.3 negotiation."
		echo ""
		echo "\`\`\`go"
		echo "// Consider removing MaxVersion to allow TLS 1.3"
		echo "tlsConfig := &tls.Config{"
		echo "    MinVersion: tls.VersionTLS12,"
		echo "    // Don't set MaxVersion unless necessary"
		echo "}"
		echo "\`\`\`"
		echo ""
		echo "### Info: Deprecated Options"
		echo ""
		echo "- **PreferServerCipherSuites**: Deprecated in Go 1.17, now a no-op"
		echo "- **MinVersion: TLS 1.3**: May break compatibility with older clients"
		echo ""
	else
		echo "## All Clear!"
		echo ""
		echo "No TLS configuration issues found in any scanned repositories."
		echo ""
	fi

	echo "---"
	echo ""
	echo "*This report was generated by [tls13-compliance-checker.sh](https://github.com/${TRACKING_REPO}/blob/main/scripts/tls13-compliance-checker.sh)*"
} >"$OUTPUT_MD"

echo -e "${GREEN}Markdown report saved to: $OUTPUT_MD${RESET}"
echo

#===============================================================================
# UPDATE CENTRAL TRACKING ISSUE
#===============================================================================

if [ "$UPDATE_TRACKING" = true ]; then
	echo -e "${BLUE}${BOLD}Updating Central Tracking Issue${RESET}"
	echo -e "${BLUE}-------------------------------------------------------${RESET}"

	# Build the issue body
	ISSUE_BODY="# TLS Configuration Compliance Report

**Last Updated:** $(date -u '+%Y-%m-%d %H:%M:%S UTC')

## Summary

- **Total Repositories Scanned:** ${TOTAL_REPOS}
- **Repositories with Issues:** ${REPOS_WITH_ISSUES}
- **Critical:** ${CRITICAL_COUNT} | **High:** ${HIGH_COUNT} | **Medium:** ${MEDIUM_COUNT} | **Info:** ${INFO_COUNT}

### Severity Legend

| Severity | Meaning |
|----------|---------|
| CRITICAL | InsecureSkipVerify: true - Disables certificate verification |
| HIGH | TLS 1.0/1.1 MinVersion or MaxVersion - Known vulnerabilities |
| MEDIUM | MaxVersion capped at TLS 1.2 - Prevents TLS 1.3 |
| INFO | Forced TLS 1.3, or PreferServerCipherSuites (deprecated) |

---

## Organizations Scanned

| Organization | Repos Scanned | Status |
|--------------|---------------|--------|
"

	# Build organizations table and track compliant orgs (reading from temp file)
	COMPLIANT_ORGS=""
	for org in "${ORGS[@]}"; do
		# Read stats from temp file (format: org|repo_count|issue_count)
		org_stats=$(grep "^${org}|" "$ORG_STATS_FILE" 2>/dev/null | head -1)
		if [ -n "$org_stats" ]; then
			repo_count=$(echo "$org_stats" | cut -d'|' -f2)
			issue_count=$(echo "$org_stats" | cut -d'|' -f3)
		else
			repo_count=0
			issue_count=0
		fi

		if [ "$repo_count" -eq 0 ]; then
			# Org had no Go repos
			ISSUE_BODY+="| ${org} | 0 | No Go repos |
"
		elif [ "$issue_count" -eq 0 ]; then
			# Fully compliant
			ISSUE_BODY+="| ${org} | ${repo_count} | ✅ Compliant |
"
			if [ -n "$COMPLIANT_ORGS" ]; then
				COMPLIANT_ORGS+="
- **${org}** (${repo_count} repositories)"
			else
				COMPLIANT_ORGS="- **${org}** (${repo_count} repositories)"
			fi
		else
			# Has issues
			ISSUE_BODY+="| ${org} | ${repo_count} | ⚠️ ${issue_count} issues |
"
		fi
	done

	ISSUE_BODY+="
"

	# Add compliant orgs highlight if any
	if [ -n "$COMPLIANT_ORGS" ]; then
		ISSUE_BODY+="### ✅ Fully Compliant Organizations

The following organizations have no TLS configuration issues:
${COMPLIANT_ORGS}

---

"
	fi

	if [ "$REPOS_WITH_ISSUES" -gt 0 ]; then
		# Create temp jq file for reliable query execution (with file hyperlinks)
		JQ_ISSUE_TABLE=$(mktemp)
		cat >"$JQ_ISSUE_TABLE" <<'JQEOF'
.repositories | to_entries | map(select(.value.findings | length > 0)) | map(select(.key | startswith($org + "/"))) | .[] | .key as $repo | .value.branch as $branch | .value.findings[] | select(.severity == $sev) |
  # Build file link - show first file as hyperlink, add count if more
  (.files | split(",") | .[0]) as $first_file |
  (.files | split(",") | length) as $file_count |
  ($first_file | split("/") | last) as $filename |
  (if $file_count > 1 then "[`" + $filename + "`](https://github.com/" + $repo + "/blob/" + $branch + "/" + $first_file + ") (+" + (($file_count - 1) | tostring) + " more)" else "[`" + $filename + "`](https://github.com/" + $repo + "/blob/" + $branch + "/" + $first_file + ")" end) as $file_link |
  "| [`" + ($repo | split("/") | last) + "`](https://github.com/" + $repo + ") | " + .pattern + " | " + $file_link + " |"
JQEOF

		# Get unique orgs that have findings
		ORGS_WITH_FINDINGS=$(jq -r '.repositories | to_entries | map(select(.value.findings | length > 0)) | .[].key | split("/")[0]' "$RESULTS_CACHE" 2>/dev/null | sort -u)

		for org in $ORGS_WITH_FINDINGS; do
			# Count total issues for this org
			org_issue_count=$(jq -r --arg org "$org" '[.repositories | to_entries | map(select(.key | startswith($org + "/"))) | .[].value.findings[]?] | length' "$RESULTS_CACHE" 2>/dev/null)

			ISSUE_BODY+="## Organization: ${org} (${org_issue_count} issues)

"

			# Group by severity within this org
			for severity in CRITICAL HIGH MEDIUM INFO; do
				# Check if there are findings for this severity in this org
				severity_count=$(jq -r --arg sev "$severity" --arg org "$org" '[.repositories | to_entries | map(select(.key | startswith($org + "/"))) | .[].value.findings[]? | select(.severity == $sev)] | length' "$RESULTS_CACHE" 2>/dev/null)

				if [ "$severity_count" -gt 0 ]; then
					ISSUE_BODY+="### ${severity} (${severity_count})

| Repository | Pattern | Files |
|------------|---------|-------|
"
					# Generate table rows from results cache (limit to 30 rows per section)
					TABLE_ROWS=$(jq -r --arg sev "$severity" --arg org "$org" -f "$JQ_ISSUE_TABLE" "$RESULTS_CACHE" 2>/dev/null | head -30)

					ISSUE_BODY+="${TABLE_ROWS}

"
				fi
			done
		done

		rm -f "$JQ_ISSUE_TABLE"

		ISSUE_BODY+="---

## Remediation Guide

### Critical: InsecureSkipVerify

**Never** set \`InsecureSkipVerify: true\` in production. This disables TLS certificate verification.

\`\`\`go
// GOOD - Verify certificates properly
tlsConfig := &tls.Config{
    RootCAs: customCertPool, // Or use system CA
}
\`\`\`

### High: Weak TLS Versions

Use TLS 1.2 minimum:

\`\`\`go
tlsConfig := &tls.Config{
    MinVersion: tls.VersionTLS12,
}
\`\`\`

"
	else
		ISSUE_BODY+="## All Clear!

No TLS configuration issues found in any scanned repositories.

"
	fi

	ISSUE_BODY+="---

## Resources

**TLS 1.3 Documentation:**
- [RFC 8446 - TLS 1.3 Specification](https://datatracker.ietf.org/doc/html/rfc8446)
- [Go crypto/tls Package](https://pkg.go.dev/crypto/tls)
- [OWASP TLS Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Transport_Layer_Security_Cheat_Sheet.html)
- [Mozilla SSL Configuration Generator](https://ssl-config.mozilla.org/)

**Security Advisories:**
- [POODLE Attack (CVE-2014-3566)](https://nvd.nist.gov/vuln/detail/CVE-2014-3566) - SSL 3.0/TLS 1.0 vulnerability
- [BEAST Attack (CVE-2011-3389)](https://nvd.nist.gov/vuln/detail/CVE-2011-3389) - TLS 1.0 vulnerability

---

*This issue is automatically updated by the [tls13-compliance-checker.sh](https://github.com/${TRACKING_REPO}/blob/main/scripts/tls13-compliance-checker.sh) script.*"

	# Check if tracking issue exists
	echo -ne "   Checking for existing tracking issue... "
	EXISTING_ISSUE=$(gh issue list --repo "$TRACKING_REPO" --search "in:title \"${TRACKING_ISSUE_TITLE}\"" --state all --json number,title,state --jq ".[] | select(.title == \"${TRACKING_ISSUE_TITLE}\") | .number" | head -1)

	if [ -n "$EXISTING_ISSUE" ]; then
		echo -e "${GREEN}found (#${EXISTING_ISSUE})${RESET}"
		echo -ne "   Updating issue #${EXISTING_ISSUE}... "

		# Check if issue is closed and reopen it if there are issues
		ISSUE_STATE=$(gh issue view "$EXISTING_ISSUE" --repo "$TRACKING_REPO" --json state --jq '.state')
		if [ "$ISSUE_STATE" = "CLOSED" ] && [ "$REPOS_WITH_ISSUES" -gt 0 ]; then
			gh issue reopen "$EXISTING_ISSUE" --repo "$TRACKING_REPO" &>/dev/null
		fi

		if gh issue edit "$EXISTING_ISSUE" --repo "$TRACKING_REPO" --body "$ISSUE_BODY" &>/dev/null; then
			echo -e "${GREEN}Updated${RESET}"
			echo -e "   ${BLUE}View at: https://github.com/${TRACKING_REPO}/issues/${EXISTING_ISSUE}${RESET}"
		else
			echo -e "${RED}Failed to update${RESET}"
		fi
	else
		echo -e "${YELLOW}not found${RESET}"
		echo -ne "   Creating new tracking issue... "

		NEW_ISSUE=$(gh issue create --repo "$TRACKING_REPO" --title "$TRACKING_ISSUE_TITLE" --body "$ISSUE_BODY" 2>/dev/null)
		if [ $? -eq 0 ]; then
			ISSUE_NUMBER=$(echo "$NEW_ISSUE" | grep -oE '[0-9]+$')
			echo -e "${GREEN}Created (#${ISSUE_NUMBER})${RESET}"
			echo -e "   ${BLUE}View at: ${NEW_ISSUE}${RESET}"
		else
			echo -e "${RED}Failed to create${RESET}"
		fi
	fi

	echo
fi

# Update cache timestamp
update_cache_timestamp

# Cleanup temporary files
rm -f "$ORG_DATA_FILE" "$ORG_STATS_FILE"

echo -e "${GREEN}${BOLD}Scan completed successfully!${RESET}"
