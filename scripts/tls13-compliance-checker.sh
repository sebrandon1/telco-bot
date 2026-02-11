#!/bin/bash

#===============================================================================
# TLS 1.3 COMPLIANCE CHECKER (Multi-Language)
#===============================================================================
#
# DESCRIPTION:
#   This script scans GitHub organizations for repositories with TLS
#   configuration issues and anti-patterns across multiple languages:
#   Go, Python, Node.js (JavaScript/TypeScript), and C++.
#
#   Uses a binary PASS/FAIL model aligned with CNF-21745: any hardcoded
#   TLS configuration that doesn't dynamically inherit from the cluster's
#   centralized tlsSecurityProfile is a FAIL. Components properly using
#   the centralized profile are a PASS.
#
#   Uses local clones for fast, rate-limit-free scanning instead of GitHub
#   Code Search API.
#
# WHAT IS DETECTED (all are FAIL findings):
#
#   Certificate verification disabled:
#     Go:     InsecureSkipVerify: true
#     Python: verify=False, ssl.CERT_NONE, _create_unverified_context,
#             check_hostname = False
#     Node:   rejectUnauthorized: false, NODE_TLS_REJECT_UNAUTHORIZED
#     C++:    SSL_CTX_set_verify(SSL_VERIFY_NONE), SSL_set_verify(SSL_VERIFY_NONE)
#
#   Weak TLS versions (1.0/1.1):
#     Go:     MinVersion/MaxVersion set to VersionTLS10/VersionTLS11
#     Python: PROTOCOL_TLSv1, PROTOCOL_TLSv1_1
#     Node:   TLSv1_method, TLSv1_1_method, minVersion TLSv1/TLSv1.1
#     C++:    TLS1_VERSION, TLS1_1_VERSION, SSLv3_method, TLSv1_method
#
#   Hardcoded TLS configuration:
#     Go:     tls.Config{} not using centralized tlsSecurityProfile
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
#     mock/, fakes/, fixtures/, node_modules/, __pycache__/, venv/, and
#     language-specific test files
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
	echo -e "${BOLD}TLS 1.3 COMPLIANCE CHECKER (Multi-Language)${RESET}"
	echo
	echo -e "${BOLD}USAGE:${RESET}"
	echo "    $(basename "$0") [OPTIONS]"
	echo
	echo -e "${BOLD}DESCRIPTION:${RESET}"
	echo "    Scans GitHub organizations for repositories with TLS configuration"
	echo "    issues and anti-patterns across Go, Python, Node.js, and C++."
	echo "    Identifies certificate verification bypass, weak TLS versions,"
	echo "    and deprecated options."
	echo
	echo -e "${BOLD}OPTIONS:${RESET}"
	echo "    -h, --help          Show this help message and exit"
	echo "    -f, --force         Force refresh cache (ignore cache age)"
	echo "    --no-tracking       Skip updating the central tracking issue"
	echo "    --mode <api|clone>  Scanning mode (default: clone)"
	echo "                        - clone: Clone repos locally, scan with grep"
	echo "                        - api: Use GitHub Code Search (for CI/CD)"
	echo
	echo -e "${BOLD}PASS/FAIL MODEL:${RESET}"
	echo "    All findings are FAIL. Repos with no findings are PASS."
	echo "    Detects: cert verification bypass, weak TLS versions, hardcoded config"
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
	echo "    Uses shared caches to skip known abandoned repos."
	echo "    Caches are stored in:"
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
	ORGS=("redhat-best-practices-for-k8s" "openshift" "openshift-kni" "redhat-openshift-ecosystem" "redhatci" "red-hat-storage")
fi

LIMIT=1000
TOTAL_REPOS=0
SKIPPED_ABANDONED=0
SKIPPED_BLOCKLIST=0
CLONE_FAILURES=0

# Finding counters
TOTAL_FINDINGS=0

# Get script directory for relative paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Shared cache files (used by all lookup scripts)
CACHE_DIR="$SCRIPT_DIR/caches"
ABANDONED_CACHE="$CACHE_DIR/abandoned.txt"
BLOCKLIST_FILE="$SCRIPT_DIR/tls13-repo-blocklist.txt"
REPO_LIST_FILE="$SCRIPT_DIR/tls13-compliance-checker-repo-list.txt"
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
touch "$ABANDONED_CACHE"

# Tracking issue configuration
TRACKING_REPO="redhat-best-practices-for-k8s/telco-bot"
TRACKING_ISSUE_TITLE="Tracking TLS Configuration Compliance"

# Supported languages for scanning
SUPPORTED_LANGUAGES=("Go" "C++" "JavaScript" "TypeScript" "Python")

# TLS patterns to search for, organized by language
# Format: "pattern_name|description|regex"
# All findings are FAIL - no severity levels

GO_TLS_PATTERNS=(
	"InsecureSkipVerify: true|Disables TLS certificate verification (MITM vulnerability)|InsecureSkipVerify[[:space:]]*:[[:space:]]*true"
	"MinVersion TLS 1.0|TLS 1.0 has known vulnerabilities (POODLE, BEAST)|MinVersion[[:space:]]*[:=][[:space:]]*.*VersionTLS10"
	"MinVersion TLS 1.1|TLS 1.1 has known vulnerabilities|MinVersion[[:space:]]*[:=][[:space:]]*.*VersionTLS11"
	"MaxVersion TLS 1.0|Limits connections to weak TLS 1.0|MaxVersion[[:space:]]*[:=][[:space:]]*.*VersionTLS10"
	"MaxVersion TLS 1.1|Limits connections to weak TLS 1.1|MaxVersion[[:space:]]*[:=][[:space:]]*.*VersionTLS11"
	"Hardcoded tls.Config|Hardcoded TLS config not using centralized tlsSecurityProfile|tls\.Config[[:space:]]*\{"
)

PYTHON_TLS_PATTERNS=(
	"verify=False|Disables TLS certificate verification (MITM vulnerability)|verify[[:space:]]*=[[:space:]]*False"
	"ssl.CERT_NONE|Disables certificate verification via ssl module|CERT_NONE"
	"_create_unverified_context|Creates SSL context without certificate verification|_create_unverified_context"
	"check_hostname = False|Disables hostname verification|check_hostname[[:space:]]*=[[:space:]]*False"
	"PROTOCOL_TLSv1 (1.0)|TLS 1.0 has known vulnerabilities (POODLE, BEAST)|PROTOCOL_TLSv1[^_]"
	"PROTOCOL_TLSv1_1|TLS 1.1 has known vulnerabilities|PROTOCOL_TLSv1_1"
)

NODE_TLS_PATTERNS=(
	"rejectUnauthorized: false|Disables TLS certificate verification (MITM vulnerability)|rejectUnauthorized[[:space:]]*:[[:space:]]*false"
	"NODE_TLS_REJECT_UNAUTHORIZED|Disables TLS verification via environment variable|NODE_TLS_REJECT_UNAUTHORIZED"
	"TLSv1_method|TLS 1.0 has known vulnerabilities (POODLE, BEAST)|TLSv1_method"
	"TLSv1_1_method|TLS 1.1 has known vulnerabilities|TLSv1_1_method"
	"minVersion TLS 1.0/1.1|Allows weak TLS versions|minVersion.*TLSv1[^.3]"
)

CPP_TLS_PATTERNS=(
	"SSL_CTX_set_verify SSL_VERIFY_NONE|Disables TLS certificate verification (MITM vulnerability)|SSL_CTX_set_verify.*SSL_VERIFY_NONE"
	"SSL_set_verify SSL_VERIFY_NONE|Disables TLS certificate verification (MITM vulnerability)|SSL_set_verify.*SSL_VERIFY_NONE"
	"TLS1_VERSION|TLS 1.0 has known vulnerabilities (POODLE, BEAST)|TLS1_VERSION[^_]"
	"TLS1_1_VERSION|TLS 1.1 has known vulnerabilities|TLS1_1_VERSION"
	"SSLv3_method|SSL 3.0 has known vulnerabilities (POODLE)|SSLv3_method"
	"TLSv1_method|TLS 1.0 has known vulnerabilities|TLSv1_method[^_]"
)

# Get TLS patterns for a given language
get_patterns_for_language() {
	local lang="$1"
	case "$lang" in
	Go) printf '%s\n' "${GO_TLS_PATTERNS[@]}" ;;
	Python) printf '%s\n' "${PYTHON_TLS_PATTERNS[@]}" ;;
	JavaScript | TypeScript) printf '%s\n' "${NODE_TLS_PATTERNS[@]}" ;;
	C++) printf '%s\n' "${CPP_TLS_PATTERNS[@]}" ;;
	esac
}

# Build grep --include flags for a language
build_include_flags() {
	local lang="$1"
	case "$lang" in
	Go) echo "--include=*.go" ;;
	Python) echo "--include=*.py" ;;
	JavaScript) echo "--include=*.js --include=*.mjs" ;;
	TypeScript) echo "--include=*.ts --include=*.mts" ;;
	C++) echo "--include=*.cpp --include=*.cc --include=*.cxx --include=*.h --include=*.hpp" ;;
	esac
}

# Build grep --exclude flags for test files by language
build_test_exclude_flags() {
	local lang="$1"
	case "$lang" in
	Go) echo "--exclude=*_test.go" ;;
	Python) echo "--exclude=*_test.py --exclude=test_*.py --exclude=conftest.py" ;;
	JavaScript) echo "--exclude=*.test.js --exclude=*.spec.js --exclude=*.test.mjs --exclude=*.spec.mjs" ;;
	TypeScript) echo "--exclude=*.test.ts --exclude=*.spec.ts --exclude=*.test.mts --exclude=*.spec.mts" ;;
	C++) echo "--exclude=*_test.cpp --exclude=*_test.cc" ;;
	esac
}

# Build extra --exclude-dir flags for language-specific directories
build_extra_exclude_dirs() {
	local lang="$1"
	case "$lang" in
	JavaScript | TypeScript) echo "--exclude-dir=node_modules" ;;
	Python) echo "--exclude-dir=__pycache__ --exclude-dir=venv --exclude-dir=.venv" ;;
	*) echo "" ;;
	esac
}

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
	local language="$3"
	local findings="[]"

	# Build language-specific grep flags
	local include_flags=$(build_include_flags "$language")
	local test_exclude_flags=$(build_test_exclude_flags "$language")
	local extra_exclude_dirs=$(build_extra_exclude_dirs "$language")

	while IFS= read -r pattern_def; do
		[ -z "$pattern_def" ] && continue
		IFS='|' read -r pattern description regex <<<"$pattern_def"

		# Search for pattern, excluding vendor, testdata, mocks, test directories, and test files
		# shellcheck disable=SC2086
		local matches=$(grep -rn $include_flags -E "$regex" "$repo_path" \
			--exclude-dir=vendor --exclude-dir=testdata --exclude-dir=mocks \
			--exclude-dir=.git --exclude-dir=test --exclude-dir=tests \
			--exclude-dir=e2e --exclude-dir=testing --exclude-dir=mock \
			--exclude-dir=fakes --exclude-dir=fixtures \
			$test_exclude_flags $extra_exclude_dirs 2>/dev/null)

		if [ -n "$matches" ]; then
			# Extract file paths (relative to repo) and count
			local files=$(echo "$matches" | cut -d: -f1 | sort -u | sed "s|$repo_path/||g" | tr '\n' ',' | sed 's/,$//')
			local count=$(echo "$matches" | wc -l | tr -d ' ')

			# Add to findings using jq (include branch for hyperlinks)
			findings=$(echo "$findings" | jq --arg p "$pattern" \
				--arg d "$description" --arg f "$files" --arg c "$count" --arg b "$branch" \
				'. + [{pattern: $p, description: $d, files: $f, count: ($c|tonumber), branch: $b}]')
		fi
	done < <(get_patterns_for_language "$language")

	# Two-pass filter for Go: reduce noise from "Hardcoded tls.Config" findings
	# If a file that matches tls.Config{} also references TLSSecurityProfile,
	# it's consuming centralized config and doing the right thing.
	if [ "$language" = "Go" ]; then
		local has_tls_config=$(echo "$findings" | jq '[.[] | select(.pattern == "Hardcoded tls.Config")] | length')
		if [ "$has_tls_config" -gt 0 ]; then
			# Check if repo has any TLSSecurityProfile references
			local profile_files=$(grep -rl --include="*.go" "TLSSecurityProfile" "$repo_path" \
				--exclude-dir=vendor --exclude-dir=testdata --exclude-dir=mocks \
				--exclude-dir=.git --exclude-dir=test --exclude-dir=tests \
				--exclude-dir=e2e --exclude-dir=testing --exclude-dir=mock \
				--exclude-dir=fakes --exclude-dir=fixtures \
				--exclude="*_test.go" 2>/dev/null)

			if [ -n "$profile_files" ]; then
				# Get the files from the tls.Config finding
				local tls_config_files=$(echo "$findings" | jq -r '.[] | select(.pattern == "Hardcoded tls.Config") | .files')
				local filtered_files=""
				local filtered_count=0

				IFS=',' read -ra file_array <<<"$tls_config_files"
				for f in "${file_array[@]}"; do
					local full_path="$repo_path/$f"
					# Keep the file only if it does NOT reference TLSSecurityProfile
					if ! grep -q "TLSSecurityProfile" "$full_path" 2>/dev/null; then
						if [ -n "$filtered_files" ]; then
							filtered_files="$filtered_files,$f"
						else
							filtered_files="$f"
						fi
						filtered_count=$((filtered_count + 1))
					fi
				done

				if [ "$filtered_count" -eq 0 ]; then
					# All files reference TLSSecurityProfile - remove finding entirely
					findings=$(echo "$findings" | jq '[.[] | select(.pattern != "Hardcoded tls.Config")]')
				elif [ "$filtered_count" -lt "$(echo "$tls_config_files" | tr ',' '\n' | wc -l | tr -d ' ')" ]; then
					# Some files filtered out - update the finding
					findings=$(echo "$findings" | jq --arg f "$filtered_files" --arg c "$filtered_count" \
						'[.[] | if .pattern == "Hardcoded tls.Config" then .files = $f | .count = ($c|tonumber) else . end]')
				fi
			fi
		fi
	fi

	echo "$findings"
}

# Helper function to update results cache
update_cache_result() {
	local repo="$1"
	local findings="$2"
	local branch="$3"
	local language="${4:-Go}"

	local timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

	# Create cache file if it doesn't exist
	if [ ! -f "$RESULTS_CACHE" ]; then
		echo '{"timestamp":"'"$timestamp"'","repositories":{}}' >"$RESULTS_CACHE"
	fi

	# Update the cache (include branch and language for hyperlinks)
	local temp_cache=$(mktemp)
	jq --arg repo "$repo" --argjson findings "$findings" --arg timestamp "$timestamp" --arg branch "$branch" --arg language "$language" \
		'.repositories[$repo] = {findings: $findings, last_checked: $timestamp, branch: $branch, language: $language}' "$RESULTS_CACHE" >"$temp_cache" 2>/dev/null && mv "$temp_cache" "$RESULTS_CACHE" || rm -f "$temp_cache"
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

# API-friendly search patterns for GitHub Code Search, organized by language
# Format: "pattern_name|description|search_query|verify_regex"
# Note: GitHub Code Search doesn't support full regex, so we use simple keywords
# and verify matches by fetching file content

GO_API_PATTERNS=(
	"InsecureSkipVerify: true|Disables TLS certificate verification (MITM vulnerability)|InsecureSkipVerify true|InsecureSkipVerify[[:space:]]*:[[:space:]]*true"
	"MinVersion TLS 1.0|TLS 1.0 has known vulnerabilities (POODLE, BEAST)|MinVersion VersionTLS10|MinVersion.*VersionTLS10"
	"MinVersion TLS 1.1|TLS 1.1 has known vulnerabilities|MinVersion VersionTLS11|MinVersion.*VersionTLS11"
	"MaxVersion TLS 1.0|Limits connections to weak TLS 1.0|MaxVersion VersionTLS10|MaxVersion.*VersionTLS10"
	"MaxVersion TLS 1.1|Limits connections to weak TLS 1.1|MaxVersion VersionTLS11|MaxVersion.*VersionTLS11"
	"Hardcoded tls.Config|Hardcoded TLS config not using centralized tlsSecurityProfile|tls.Config|tls\.Config[[:space:]]*\{"
)

PYTHON_API_PATTERNS=(
	"verify=False|Disables TLS certificate verification (MITM vulnerability)|verify False|verify[[:space:]]*=[[:space:]]*False"
	"ssl.CERT_NONE|Disables certificate verification via ssl module|CERT_NONE|CERT_NONE"
	"_create_unverified_context|Creates SSL context without certificate verification|_create_unverified_context|_create_unverified_context"
	"check_hostname = False|Disables hostname verification|check_hostname False|check_hostname[[:space:]]*=[[:space:]]*False"
	"PROTOCOL_TLSv1 (1.0)|TLS 1.0 has known vulnerabilities (POODLE, BEAST)|PROTOCOL_TLSv1|PROTOCOL_TLSv1[^_]"
	"PROTOCOL_TLSv1_1|TLS 1.1 has known vulnerabilities|PROTOCOL_TLSv1_1|PROTOCOL_TLSv1_1"
)

NODE_API_PATTERNS=(
	"rejectUnauthorized: false|Disables TLS certificate verification (MITM vulnerability)|rejectUnauthorized false|rejectUnauthorized[[:space:]]*:[[:space:]]*false"
	"NODE_TLS_REJECT_UNAUTHORIZED|Disables TLS verification via environment variable|NODE_TLS_REJECT_UNAUTHORIZED|NODE_TLS_REJECT_UNAUTHORIZED"
	"TLSv1_method|TLS 1.0 has known vulnerabilities (POODLE, BEAST)|TLSv1_method|TLSv1_method"
	"TLSv1_1_method|TLS 1.1 has known vulnerabilities|TLSv1_1_method|TLSv1_1_method"
	"minVersion TLS 1.0/1.1|Allows weak TLS versions|minVersion TLSv1|minVersion.*TLSv1[^.3]"
)

CPP_API_PATTERNS=(
	"SSL_CTX_set_verify SSL_VERIFY_NONE|Disables TLS certificate verification (MITM vulnerability)|SSL_VERIFY_NONE|SSL_CTX_set_verify.*SSL_VERIFY_NONE"
	"SSL_set_verify SSL_VERIFY_NONE|Disables TLS certificate verification (MITM vulnerability)|SSL_set_verify SSL_VERIFY_NONE|SSL_set_verify.*SSL_VERIFY_NONE"
	"TLS1_VERSION|TLS 1.0 has known vulnerabilities (POODLE, BEAST)|TLS1_VERSION|TLS1_VERSION[^_]"
	"TLS1_1_VERSION|TLS 1.1 has known vulnerabilities|TLS1_1_VERSION|TLS1_1_VERSION"
	"SSLv3_method|SSL 3.0 has known vulnerabilities (POODLE)|SSLv3_method|SSLv3_method"
	"TLSv1_method|TLS 1.0 has known vulnerabilities|TLSv1_method|TLSv1_method[^_]"
)

# Get API patterns for a given language
get_api_patterns_for_language() {
	local lang="$1"
	case "$lang" in
	Go) printf '%s\n' "${GO_API_PATTERNS[@]}" ;;
	Python) printf '%s\n' "${PYTHON_API_PATTERNS[@]}" ;;
	JavaScript | TypeScript) printf '%s\n' "${NODE_API_PATTERNS[@]}" ;;
	C++) printf '%s\n' "${CPP_API_PATTERNS[@]}" ;;
	esac
}

# Get GitHub Code Search --language flag value for a language
get_search_language() {
	local lang="$1"
	case "$lang" in
	Go) echo "go" ;;
	Python) echo "python" ;;
	JavaScript) echo "javascript" ;;
	TypeScript) echo "typescript" ;;
	C++) echo "c++" ;;
	esac
}

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

	# Exclude vendor, test directories, test files, and language-specific dirs
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
	node_modules/* | */node_modules/*) return 0 ;;
	__pycache__/* | */__pycache__/*) return 0 ;;
	.venv/* | */.venv/* | venv/* | */venv/*) return 0 ;;
	__tests__/* | */__tests__/*) return 0 ;;
	*_test.go) return 0 ;;
	*_test.py | test_*.py | conftest.py) return 0 ;;
	*.test.js | *.spec.js | *.test.ts | *.spec.ts) return 0 ;;
	*_test.cpp | *_test.cc) return 0 ;;
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
	local language="$3"
	local findings="[]"
	local search_lang=$(get_search_language "$language")

	# Check if repo is a fork (GitHub Code Search API doesn't index most forks)
	local is_fork=$(gh api "repos/$repo" --jq '.fork' 2>/dev/null)
	local use_tree_fallback=false

	while IFS= read -r pattern_def; do
		[ -z "$pattern_def" ] && continue
		IFS='|' read -r pattern description search_query verify_regex <<<"$pattern_def"

		if [ "$use_tree_fallback" = true ]; then
			# Already using tree fallback, skip API search
			continue
		fi

		# Rate limit
		api_rate_limit

		# Build full query with exclusions
		# GitHub Code Search supports NOT path: syntax in the query string
		# Note: We exclude common test/vendor directories directly in the search
		local full_query="${search_query} NOT path:vendor/ NOT path:testdata/ NOT path:mocks/ NOT path:mock/ NOT path:test/ NOT path:tests/ NOT path:e2e/ NOT path:testing/ NOT path:fakes/ NOT path:fixtures/ NOT path:node_modules/ NOT path:__pycache__/ NOT path:venv/ NOT path:.venv/"

		# Search using gh search code with exclusions in the query
		local search_result=$(gh search code "$full_query" \
			--repo "$repo" \
			--language "$search_lang" \
			--limit 100 \
			--json path 2>/dev/null)

		if [ -z "$search_result" ] || [ "$search_result" = "[]" ] || [ "$search_result" = "null" ]; then
			# If this is a fork and first pattern returned no results, switch to tree fallback
			if [ "$is_fork" = "true" ]; then
				echo -e "\n      ${YELLOW}Warning: $repo is a fork (GitHub Code Search doesn't index forks). Using file tree fallback...${RESET}" >&2
				use_tree_fallback=true
			fi
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
			findings=$(echo "$findings" | jq --arg p "$pattern" \
				--arg d "$description" --arg f "$verified_files" --arg c "$verified_count" --arg b "$branch" \
				'. + [{pattern: $p, description: $d, files: $f, count: ($c|tonumber), branch: $b}]')
		fi
	done < <(get_api_patterns_for_language "$language")

	# Fork fallback: fetch file tree and scan individual files
	if [ "$use_tree_fallback" = true ]; then
		findings=$(scan_fork_repo_api "$repo" "$branch" "$language" "$findings")
	fi

	echo "$findings"
}

# Fallback scanner for fork repos: fetch file tree via GitHub API, then check files individually
scan_fork_repo_api() {
	local repo="$1"
	local branch="$2"
	local language="$3"
	local findings="$4"

	# Get file extensions for this language
	local extensions=""
	case "$language" in
	Go) extensions=".go" ;;
	Python) extensions=".py" ;;
	JavaScript) extensions=".js .mjs" ;;
	TypeScript) extensions=".ts .mts" ;;
	C++) extensions=".cpp .cc .cxx .h .hpp" ;;
	esac

	# Fetch the repo tree
	local tree_json=$(gh api "repos/$repo/git/trees/$branch?recursive=1" --jq '.tree[] | select(.type == "blob") | .path' 2>/dev/null)

	if [ -z "$tree_json" ]; then
		return 0
	fi

	# Filter to relevant file extensions and exclude test/vendor paths
	local relevant_files=""
	while IFS= read -r filepath; do
		[ -z "$filepath" ] && continue

		# Check extension matches
		local ext_match=false
		for ext in $extensions; do
			if [[ "$filepath" == *"$ext" ]]; then
				ext_match=true
				break
			fi
		done
		$ext_match || continue

		# Exclude test/vendor paths
		should_exclude_path "$filepath" && continue

		if [ -n "$relevant_files" ]; then
			relevant_files="$relevant_files"$'\n'"$filepath"
		else
			relevant_files="$filepath"
		fi
	done <<<"$tree_json"

	if [ -z "$relevant_files" ]; then
		echo "$findings"
		return 0
	fi

	# Check each pattern against the relevant files
	while IFS= read -r pattern_def; do
		[ -z "$pattern_def" ] && continue
		IFS='|' read -r pattern description _ verify_regex <<<"$pattern_def"

		local verified_files=""
		local verified_count=0

		while IFS= read -r filepath; do
			[ -z "$filepath" ] && continue

			if verify_match_in_file "$repo" "$branch" "$filepath" "$verify_regex"; then
				if [ -n "$verified_files" ]; then
					verified_files="$verified_files,$filepath"
				else
					verified_files="$filepath"
				fi
				verified_count=$((verified_count + 1))
			fi
		done <<<"$relevant_files"

		if [ $verified_count -gt 0 ]; then
			findings=$(echo "$findings" | jq --arg p "$pattern" \
				--arg d "$description" --arg f "$verified_files" --arg c "$verified_count" --arg b "$branch" \
				'. + [{pattern: $p, description: $d, files: $f, count: ($c|tonumber), branch: $b}]')
		fi
	done < <(get_api_patterns_for_language "$language")

	echo "$findings"
}

#===============================================================================
# LOAD CACHES
#===============================================================================

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

# Temporary file to store org-specific data for tracking issue
ORG_DATA_FILE=$(mktemp)

# Temporary file to track per-org statistics (bash 3.x compatible)
ORG_STATS_FILE=$(mktemp)

# Repos with findings (FAIL) vs without (PASS)
FAIL_REPOS=0
PASS_REPOS=0

echo -e "${BLUE}${BOLD}SCANNING REPOSITORIES FOR TLS CONFIGURATION ISSUES${RESET}"
echo -e "${BLUE}=======================================================${RESET}"
echo -e "${YELLOW}Languages: Go, Python, JavaScript/TypeScript, C++${RESET}"
echo -e "${YELLOW}Model: PASS/FAIL (any finding = FAIL)${RESET}"
echo -e "${YELLOW}Checking for: certificate verification bypass, weak TLS versions,${RESET}"
echo -e "${YELLOW}              hardcoded TLS config not using centralized profile${RESET}"
echo -e "${BLUE}-------------------------------------------------------${RESET}"
echo

for ORG_NAME in "${ORGS[@]}"; do
	echo -e "${YELLOW}${BOLD}Organization: ${ORG_NAME}${RESET}"

	# Get all repos (supported languages, non-archived)
	echo -e "${BLUE}   Fetching repository list...${RESET}"
	REPOS=$(gh repo list "$ORG_NAME" --limit "$LIMIT" --json nameWithOwner,defaultBranchRef,isArchived,primaryLanguage -q '.[] | select(.isArchived == false) | select(.primaryLanguage.name == ("Go","C++","JavaScript","TypeScript","Python")) | .nameWithOwner + " " + .defaultBranchRef.name + " " + .primaryLanguage.name')
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
	ORG_FINDINGS=0

	while read -r repo branch language; do
		# Skip empty lines
		[[ -z "$repo" ]] && continue

		# Show progress indicator
		echo -ne "   ${repo} [${language}] on branch ${branch}... "

		# Check if repo is blocklisted
		if is_blocklisted "$repo"; then
			echo -e "${BLUE}skipped (blocklisted)${RESET}"
			SKIPPED_BLOCKLIST=$((SKIPPED_BLOCKLIST + 1))
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

		# Check results cache first
		if [ "$CACHE_VALID" = true ]; then
			cached_result=$(get_cached_result "$repo")
			if [ "$cached_result" != "null" ]; then
				# Parse cached findings
				cached_findings=$(echo "$cached_result" | jq '.findings')
				if [ "$cached_findings" != "null" ] && [ "$cached_findings" != "[]" ]; then
					echo -e "${YELLOW}FAIL (cached)${RESET}"

					# Count findings from cache
					local cached_count=$(echo "$cached_findings" | jq 'length')
					ORG_FINDINGS=$((ORG_FINDINGS + cached_count))

					# Store for report
					echo "$ORG_NAME|$repo|$branch|$(echo "$cached_findings" | jq -c '.')" >>"$ORG_DATA_FILE"
					continue
				elif [ "$cached_findings" = "[]" ]; then
					echo -e "${GREEN}PASS (cached)${RESET}"
					continue
				fi
			fi
		fi

		# Perform scanning based on mode
		if [ "$SCAN_MODE" = "api" ]; then
			# API mode: use GitHub Code Search
			findings=$(scan_repo_api "$repo" "$branch" "$language")
		else
			# Clone mode: ensure repo is cloned and up-to-date
			repo_path=$(ensure_repo_updated "$repo" "$branch")
			if [ -z "$repo_path" ] || [ ! -d "$repo_path" ]; then
				echo -e "${RED}clone failed${RESET}"
				CLONE_FAILURES=$((CLONE_FAILURES + 1))
				continue
			fi

			# Perform TLS pattern search using grep
			findings=$(scan_local_repo "$repo_path" "$branch" "$language")
		fi

		if [ -z "$findings" ] || [ "$findings" = "[]" ] || [ "$findings" = "null" ]; then
			echo -e "${GREEN}PASS${RESET}"
			update_cache_result "$repo" "[]" "$branch" "$language"
		else
			finding_count=$(echo "$findings" | jq 'length')
			echo -e "${RED}FAIL (${finding_count} finding(s))${RESET}"

			# Update cache
			update_cache_result "$repo" "$findings" "$branch" "$language"

			# Count findings
			ORG_FINDINGS=$((ORG_FINDINGS + finding_count))

			# Store for report
			echo "$ORG_NAME|$repo|$branch|$(echo "$findings" | jq -c '.')" >>"$ORG_DATA_FILE"
		fi

	done <<<"$REPOS"

	# Update global counters
	TOTAL_FINDINGS=$((TOTAL_FINDINGS + ORG_FINDINGS))

	# Track total issues for this org and save to stats file
	echo "${ORG_NAME}|${REPO_COUNT}|${ORG_FINDINGS}" >>"$ORG_STATS_FILE"

	# Summary for this organization
	echo
	echo -e "${YELLOW}${BOLD}Summary for ${ORG_NAME}:${RESET}"
	if [ "$ORG_FINDINGS" -gt 0 ]; then
		echo -e "   ${RED}FAIL: ${ORG_FINDINGS} finding(s)${RESET}"
	else
		echo -e "   ${GREEN}PASS: No findings${RESET}"
	fi
	echo -e "${BLUE}-------------------------------------------------------${RESET}"
	echo
done

#===============================================================================
# SCAN EXPLICIT REPO LIST (fork repos and manually added repos)
#===============================================================================

if [ -f "$REPO_LIST_FILE" ]; then
	echo -e "${YELLOW}${BOLD}Scanning explicit repo list: ${REPO_LIST_FILE}${RESET}"
	echo

	while IFS= read -r line || [ -n "$line" ]; do
		# Skip empty lines and comments
		[[ -z "$line" || "$line" =~ ^[[:space:]]*(#|//) ]] && continue

		# Normalize the repo name
		repo=$(echo "$line" | sed -e 's|https://github.com/||' -e 's|github.com/||' -e 's|^[[:space:]]*||' -e 's|[[:space:]]*$||')
		[ -z "$repo" ] && continue

		# Check if this repo was already scanned in the org loop
		if [ -f "$RESULTS_CACHE" ]; then
			cached=$(jq -r ".repositories[\"$repo\"] // null" "$RESULTS_CACHE" 2>/dev/null)
			if [ "$cached" != "null" ]; then
				echo -e "   ${repo}... ${BLUE}already scanned${RESET}"
				continue
			fi
		fi

		# Check if repo is blocklisted
		if is_blocklisted "$repo"; then
			echo -e "   ${repo}... ${BLUE}skipped (blocklisted)${RESET}"
			continue
		fi

		# Get repo info (branch, language)
		repo_info=$(gh api "repos/$repo" --jq '{branch: .default_branch, language: .language, archived: .archived, fork: .fork}' 2>/dev/null)
		if [ -z "$repo_info" ]; then
			echo -e "   ${repo}... ${RED}not found${RESET}"
			continue
		fi

		branch=$(echo "$repo_info" | jq -r '.branch')
		language=$(echo "$repo_info" | jq -r '.language')
		is_archived=$(echo "$repo_info" | jq -r '.archived')
		is_fork=$(echo "$repo_info" | jq -r '.fork')

		if [ "$is_archived" = "true" ]; then
			echo -e "   ${repo}... ${BLUE}skipped (archived)${RESET}"
			continue
		fi

		# Normalize language name
		case "$language" in
		Go | C++ | JavaScript | TypeScript | Python) ;;
		*)
			echo -e "   ${repo} [${language}]... ${BLUE}skipped (unsupported language)${RESET}"
			continue
			;;
		esac

		echo -ne "   ${repo} [${language}] on branch ${branch}"
		[ "$is_fork" = "true" ] && echo -ne " (fork)"
		echo -ne "... "

		TOTAL_REPOS=$((TOTAL_REPOS + 1))

		# Perform scanning based on mode
		if [ "$SCAN_MODE" = "api" ]; then
			findings=$(scan_repo_api "$repo" "$branch" "$language")
		else
			repo_path=$(ensure_repo_updated "$repo" "$branch")
			if [ -z "$repo_path" ] || [ ! -d "$repo_path" ]; then
				echo -e "${RED}clone failed${RESET}"
				CLONE_FAILURES=$((CLONE_FAILURES + 1))
				continue
			fi
			findings=$(scan_local_repo "$repo_path" "$branch" "$language")
		fi

		if [ -z "$findings" ] || [ "$findings" = "[]" ] || [ "$findings" = "null" ]; then
			echo -e "${GREEN}PASS${RESET}"
			update_cache_result "$repo" "[]" "$branch" "$language"
		else
			finding_count=$(echo "$findings" | jq 'length')
			echo -e "${RED}FAIL (${finding_count} finding(s))${RESET}"
			update_cache_result "$repo" "$findings" "$branch" "$language"
			TOTAL_FINDINGS=$((TOTAL_FINDINGS + finding_count))

			# Determine org for reporting
			local_org="${repo%%/*}"
			echo "$local_org|$repo|$branch|$(echo "$findings" | jq -c '.')" >>"$ORG_DATA_FILE"
		fi
	done <"$REPO_LIST_FILE"

	echo -e "${BLUE}-------------------------------------------------------${RESET}"
	echo
fi

# Sort and deduplicate caches
if [ -f "$ABANDONED_CACHE" ] && [ -s "$ABANDONED_CACHE" ]; then
	sort -u "$ABANDONED_CACHE" -o "$ABANDONED_CACHE"
fi

# Calculate totals
TOTAL_ISSUES=$TOTAL_FINDINGS
REPOS_WITH_ISSUES=$(wc -l <"$ORG_DATA_FILE" 2>/dev/null | tr -d ' ')
REPOS_WITH_ISSUES=${REPOS_WITH_ISSUES:-0}

# Final summary
echo -e "${BOLD}${BLUE}FINAL RESULTS:${RESET}"
echo -e "${BOLD}   Total repositories scanned:${RESET} ${TOTAL_REPOS}"
echo -e "${BOLD}   Repositories skipped (abandoned):${RESET} ${BLUE}${SKIPPED_ABANDONED}${RESET}"
echo -e "${BOLD}   Repositories skipped (blocklisted):${RESET} ${BLUE}${SKIPPED_BLOCKLIST}${RESET}"
if [ "$SCAN_MODE" = "clone" ] && [ "$CLONE_FAILURES" -gt 0 ]; then
	echo -e "${BOLD}   Clone failures:${RESET} ${RED}${CLONE_FAILURES}${RESET}"
fi
echo -e "${BOLD}   Scan mode:${RESET} ${SCAN_MODE}"
echo -e "${BOLD}   Repositories with issues:${RESET} ${YELLOW}${REPOS_WITH_ISSUES}${RESET}"
echo
if [ "$REPOS_WITH_ISSUES" -gt 0 ]; then
	echo -e "${BOLD}${RED}RESULT: FAIL${RESET} (${TOTAL_ISSUES} finding(s) in ${REPOS_WITH_ISSUES} repos)"
else
	echo -e "${BOLD}${GREEN}RESULT: PASS${RESET} (all repos compliant)"
fi
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
	echo "- **Repositories with findings (FAIL):** ${REPOS_WITH_ISSUES}"
	echo "- **Total findings:** ${TOTAL_ISSUES}"
	echo ""
	echo "## Pass/Fail Model"
	echo ""
	echo "Any hardcoded TLS configuration that does not dynamically inherit from the cluster's"
	echo "centralized \`tlsSecurityProfile\` is a **FAIL**. This aligns with CNF-21745 requirements."
	echo ""

	if [ "$REPOS_WITH_ISSUES" -gt 0 ]; then
		echo "## Findings by Organization"
		echo ""

		# Create temp jq file for reliable query execution (with file hyperlinks)
		JQ_MD_TABLE=$(mktemp)
		cat >"$JQ_MD_TABLE" <<'JQEOF'
.repositories | to_entries | map(select(.value.findings | length > 0)) | map(select(.key | startswith($org + "/"))) | .[] | .key as $repo | .value.branch as $branch | .value.findings[] |
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

			echo "### Organization: ${org} (${org_issue_count} findings - FAIL)"
			echo ""
			echo "| Repository | Pattern | Files | Description |"
			echo "|------------|---------|-------|-------------|"

			jq -r --arg org "$org" -f "$JQ_MD_TABLE" "$RESULTS_CACHE" 2>/dev/null

			echo ""
		done

		rm -f "$JQ_MD_TABLE"

		echo "## Remediation"
		echo ""
		echo "All findings indicate TLS configurations that should use the cluster's centralized"
		echo "\`tlsSecurityProfile\` instead of hardcoded settings (CNF-21745)."
		echo ""
		echo "### Certificate Verification"
		echo ""
		echo "Never disable certificate verification. Remove \`InsecureSkipVerify: true\`,"
		echo "\`verify=False\`, \`rejectUnauthorized: false\`, or \`SSL_VERIFY_NONE\`."
		echo ""
		echo "### Weak TLS Versions"
		echo ""
		echo "Remove references to TLS 1.0/1.1. Use TLS 1.2 minimum."
		echo ""
		echo "### Hardcoded tls.Config"
		echo ""
		echo "Use the centralized \`TLSSecurityProfile\` from the API server instead of"
		echo "hardcoding \`tls.Config{}\` structs."
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
- **Repositories with Findings (FAIL):** ${REPOS_WITH_ISSUES}
- **Total Findings:** ${TOTAL_ISSUES}

### Model

**PASS/FAIL** - Any hardcoded TLS configuration that does not dynamically inherit from the cluster's centralized \`tlsSecurityProfile\` is a FAIL (CNF-21745).

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
			# Org had no repos in supported languages
			ISSUE_BODY+="| ${org} | 0 | No repos |
"
		elif [ "$issue_count" -eq 0 ]; then
			# Fully compliant
			ISSUE_BODY+="| ${org} | ${repo_count} | ✅ PASS |
"
			if [ -n "$COMPLIANT_ORGS" ]; then
				COMPLIANT_ORGS+="
- **${org}** (${repo_count} repositories)"
			else
				COMPLIANT_ORGS="- **${org}** (${repo_count} repositories)"
			fi
		else
			# Has findings
			ISSUE_BODY+="| ${org} | ${repo_count} | ❌ FAIL (${issue_count} findings) |
"
		fi
	done

	ISSUE_BODY+="
"

	# Add compliant orgs highlight if any
	if [ -n "$COMPLIANT_ORGS" ]; then
		ISSUE_BODY+="### ✅ Passing Organizations

The following organizations have no TLS findings:
${COMPLIANT_ORGS}

---

"
	fi

	if [ "$REPOS_WITH_ISSUES" -gt 0 ]; then
		# Create temp jq file for reliable query execution (with file hyperlinks)
		JQ_ISSUE_TABLE=$(mktemp)
		cat >"$JQ_ISSUE_TABLE" <<'JQEOF'
.repositories | to_entries | map(select(.value.findings | length > 0)) | map(select(.key | startswith($org + "/"))) | .[] | .key as $repo | .value.branch as $branch | .value.findings[] |
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
			# Count total findings for this org
			org_issue_count=$(jq -r --arg org "$org" '[.repositories | to_entries | map(select(.key | startswith($org + "/"))) | .[].value.findings[]?] | length' "$RESULTS_CACHE" 2>/dev/null)

			ISSUE_BODY+="## Organization: ${org} (${org_issue_count} findings - FAIL)

| Repository | Pattern | Files |
|------------|---------|-------|
"
			# Generate table rows from results cache (limit to 30 rows per section)
			TABLE_ROWS=$(jq -r --arg org "$org" -f "$JQ_ISSUE_TABLE" "$RESULTS_CACHE" 2>/dev/null | head -30)

			ISSUE_BODY+="${TABLE_ROWS}

"
		done

		rm -f "$JQ_ISSUE_TABLE"

		ISSUE_BODY+="---

## Remediation

All findings indicate TLS configurations that should use the cluster's centralized \`tlsSecurityProfile\` instead of hardcoded settings (CNF-21745).

- **Certificate Verification:** Never disable it. Remove InsecureSkipVerify, verify=False, rejectUnauthorized: false, SSL_VERIFY_NONE.
- **Weak TLS Versions:** Remove TLS 1.0/1.1 references. Use TLS 1.2 minimum.
- **Hardcoded tls.Config:** Use the centralized \`TLSSecurityProfile\` from the API server.

"
	else
		ISSUE_BODY+="## Result: PASS

All scanned repositories are compliant. No hardcoded TLS configuration issues found.

"
	fi

	ISSUE_BODY+="---

## Resources

- [RFC 8446 - TLS 1.3 Specification](https://datatracker.ietf.org/doc/html/rfc8446)
- [OWASP TLS Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Transport_Layer_Security_Cheat_Sheet.html)
- [OpenShift TLSSecurityProfile Docs](https://docs.openshift.com/container-platform/latest/security/tls-security-profiles.html)
- [CNF-21745 - OCP 4.22 TLS Compliance](https://issues.redhat.com/browse/CNF-21745)

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
