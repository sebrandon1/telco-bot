#!/bin/bash

#===============================================================================
# FIND DOWNSTREAM REPOS
#===============================================================================
#
# DESCRIPTION:
#   This script scans GitHub organizations (primarily OpenShift) to identify
#   repositories that are likely downstream forks or mirrors of upstream
#   projects. These repositories typically shouldn't receive automated Go
#   version update issues as they need to stay in sync with their upstream.
#
# PREREQUISITES:
#   1. GitHub CLI (gh) must be installed and authenticated
#   2. Internet connection to fetch repository data
#
# USAGE:
#   ./find-downstream-repos.sh [OPTIONS]
#
# OPTIONS:
#   --org ORG_NAME    Organization to scan (default: openshift)
#   --limit NUMBER    Maximum repositories to fetch (default: 1000)
#   --output FILE     Output file (default: stdout)
#   --help            Show this help message
#
# OUTPUT:
#   List of repository names in format suitable for go-version-repo-blocklist.txt
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

# Parse command line arguments
ORG_NAME="openshift"
LIMIT=1000
OUTPUT_FILE=""

while [[ $# -gt 0 ]]; do
	case $1 in
	--org)
		ORG_NAME="$2"
		shift 2
		;;
	--limit)
		LIMIT="$2"
		shift 2
		;;
	--output)
		OUTPUT_FILE="$2"
		shift 2
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

echo -e "${BLUE}${BOLD}🔍 FINDING DOWNSTREAM REPOSITORIES${RESET}" >&2
echo -e "${BLUE}─────────────────────────────────────────────────────${RESET}" >&2
echo -e "${BLUE}Organization: ${ORG_NAME}${RESET}" >&2
echo -e "${BLUE}Limit: ${LIMIT} repositories${RESET}" >&2
echo >&2

# Fetch all repositories from the organization
echo -e "${BLUE}📡 Fetching repository list from ${ORG_NAME}...${RESET}" >&2
REPOS=$(gh repo list "$ORG_NAME" --limit "$LIMIT" --json nameWithOwner,isFork,parent,description -q '.[]')

if [[ $? -ne 0 ]]; then
	echo -e "${RED}❌ Failed to fetch repositories from ${ORG_NAME}${RESET}" >&2
	exit 1
fi

REPO_COUNT=$(echo "$REPOS" | jq -s 'length')
echo -e "${GREEN}✅ Found ${REPO_COUNT} repositories${RESET}" >&2
echo >&2

# Common upstream project names that indicate downstream repos
UPSTREAM_PATTERNS=(
	"prometheus"
	"grafana"
	"thanos"
	"alertmanager"
	"node-exporter"
	"kube-state-metrics"
	"blackbox-exporter"
	"pushgateway"
	"statsd-exporter"
	"configmap-reload"
	"telemeter"
	"cluster-monitoring-operator"
	"prom-label-proxy"
	"apiserver-network-proxy"
	"coredns"
	"etcd"
	"oauth-proxy"
	"opentelemetry"
	"jaeger"
	"tempo"
	"loki"
	"cortex"
	"mimir"
)

echo -e "${YELLOW}${BOLD}📋 IDENTIFIED DOWNSTREAM REPOSITORIES${RESET}" >&2
echo -e "${YELLOW}─────────────────────────────────────────────────────${RESET}" >&2
echo >&2

# Arrays to store different categories
FORK_REPOS=()
SUSPECTED_DOWNSTREAM=()

# Process each repository
echo "$REPOS" | jq -c '.' | while IFS= read -r repo_json; do
	repo_name=$(echo "$repo_json" | jq -r '.nameWithOwner')
	is_fork=$(echo "$repo_json" | jq -r '.isFork')
	parent=$(echo "$repo_json" | jq -r '.parent.nameWithOwner // empty')
	description=$(echo "$repo_json" | jq -r '.description // ""')

	repo_basename=$(basename "$repo_name")

	# Check if it's a fork
	if [ "$is_fork" = "true" ]; then
		echo "$repo_name" # Output to stdout for capture
		if [ -n "$parent" ]; then
			echo -e "  ${GREEN}✓${RESET} ${repo_name} ${BLUE}(fork of ${parent})${RESET}" >&2
		else
			echo -e "  ${GREEN}✓${RESET} ${repo_name} ${BLUE}(fork)${RESET}" >&2
		fi
		continue
	fi

	# Check if repo name matches common upstream patterns
	for pattern in "${UPSTREAM_PATTERNS[@]}"; do
		if echo "$repo_basename" | grep -qi "$pattern"; then
			echo "$repo_name" # Output to stdout for capture
			echo -e "  ${YELLOW}~${RESET} ${repo_name} ${BLUE}(matches pattern: ${pattern})${RESET}" >&2
			break
		fi
	done

	# Check if description mentions "downstream" or "mirror" or "fork"
	if echo "$description" | grep -qiE "(downstream|mirror|fork of|based on|vendored)"; then
		echo "$repo_name" # Output to stdout for capture
		echo -e "  ${YELLOW}~${RESET} ${repo_name} ${BLUE}(description suggests downstream)${RESET}" >&2
	fi
done | sort -u >"${OUTPUT_FILE:-/dev/stdout}"

if [ -n "$OUTPUT_FILE" ]; then
	FOUND_COUNT=$(wc -l <"$OUTPUT_FILE" | tr -d ' ')
	echo >&2
	echo -e "${GREEN}${BOLD}✅ Found ${FOUND_COUNT} potential downstream repositories${RESET}" >&2
	echo -e "${BLUE}Results written to: ${OUTPUT_FILE}${RESET}" >&2
	echo >&2
	echo -e "${YELLOW}💡 Review the list and add desired repositories to:${RESET}" >&2
	echo -e "${YELLOW}   scripts/go-version-repo-blocklist.txt${RESET}" >&2
else
	echo >&2
	echo -e "${GREEN}${BOLD}✅ Scan complete${RESET}" >&2
	echo >&2
	echo -e "${YELLOW}💡 To save to a file, use: --output <filename>${RESET}" >&2
	echo -e "${YELLOW}   Example: ./find-downstream-repos.sh --output downstream-repos.txt${RESET}" >&2
fi
