#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/slack.sh"

calculate_pull_repo_jobs() {
	local json_file=$1
	jq '.aggregated[] | select(.kind == "pull_repo") | .count' "$json_file" | awk '{s+=$1} END {print s}'
}

if [ "$#" -lt 7 ]; then
	echo "Usage: $0 <SLACK_WEBHOOK_URL> <JSON_FILE_LEGACY> <JSON_FILE_CURRENT> <START_DATE> <END_DATE> <REPO_NAME_LEGACY> <REPO_NAME_CURRENT>"
	exit 1
fi

SLACK_WEBHOOK_URL=$1
JSON_FILE_LEGACY=$2
JSON_FILE_CURRENT=$3
START_DATE=$4
END_DATE=$5
REPO_NAME_LEGACY=$6
REPO_NAME_CURRENT=$7

validate_json "$JSON_FILE_LEGACY" || exit 1
validate_json "$JSON_FILE_CURRENT" || exit 1

NUMBER_OF_PULL_REPO_JOBS_LEGACY=$(calculate_pull_repo_jobs "$JSON_FILE_LEGACY")
NUMBER_OF_PULL_REPO_JOBS_CURRENT=$(calculate_pull_repo_jobs "$JSON_FILE_CURRENT")
TOTAL_PULL_REPO_JOBS=$((NUMBER_OF_PULL_REPO_JOBS_LEGACY + NUMBER_OF_PULL_REPO_JOBS_CURRENT))

if [ "$TOTAL_PULL_REPO_JOBS" -gt 0 ]; then
	MIGRATION_PCT=$(awk "BEGIN {printf \"%.0f\", ($NUMBER_OF_PULL_REPO_JOBS_CURRENT / $TOTAL_PULL_REPO_JOBS) * 100}")
else
	MIGRATION_PCT=0
fi

TOTAL_FORMATTED=$(printf "%'d" "$TOTAL_PULL_REPO_JOBS")

MESSAGE=":package: Certsuite Quay Pull Report
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

:calendar: Period: ${START_DATE} — ${END_DATE}
:arrow_down: Total Pulls: ${TOTAL_FORMATTED}

   ${REPO_NAME_CURRENT}: ${NUMBER_OF_PULL_REPO_JOBS_CURRENT}
   ${REPO_NAME_LEGACY}: ${NUMBER_OF_PULL_REPO_JOBS_LEGACY}

:chart_with_upwards_trend: Migration Progress: ${MIGRATION_PCT}% on current repo"

send_slack_message "$SLACK_WEBHOOK_URL" "$MESSAGE"
