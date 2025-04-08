#!/bin/bash

# Function to validate required tools
dependencies_check() {
	for cmd in jq curl; do
		if ! command -v $cmd &>/dev/null; then
			echo "$cmd is required but not installed. Exiting."
			exit 1
		fi
	done
}

# Function to calculate the total count of jobs with 'kind: pull_repo'
calculate_pull_repo_jobs() {
	local json_file=$1
	jq '.aggregated[] | select(.kind == "pull_repo") | .count' "$json_file" | awk '{s+=$1} END {print s}'
}

# Validate arguments
if [ "$#" -lt 7 ]; then
	echo "Usage: $0 <SLACK_WEBHOOK_URL> <JSON_FILE_LEGACY> <JSON_FILE_CURRENT> <START_DATE> <END_DATE> <REPO_NAME_LEGACY> <REPO_NAME_CURRENT>"
	exit 1
fi

# Collect the arguments
SLACK_WEBHOOK_URL=$1
JSON_FILE_LEGACY=$2
JSON_FILE_CURRENT=$3
START_DATE=$4
END_DATE=$5
REPO_NAME_LEGACY=$6
REPO_NAME_CURRENT=$7

# Check dependencies
dependencies_check

# Calculate the number of pull_repo jobs
NUMBER_OF_PULL_REPO_JOBS_LEGACY=$(calculate_pull_repo_jobs "$JSON_FILE_LEGACY")
NUMBER_OF_PULL_REPO_JOBS_CURRENT=$(calculate_pull_repo_jobs "$JSON_FILE_CURRENT")

TOTAL_PULL_REPO_JOBS=$(($NUMBER_OF_PULL_REPO_JOBS_LEGACY + $NUMBER_OF_PULL_REPO_JOBS_CURRENT))

MESSAGE="The following images have been pulled $TOTAL_PULL_REPO_JOBS times between $START_DATE and $END_DATE:\n\n"

MESSAGE+="$REPO_NAME_LEGACY: $NUMBER_OF_PULL_REPO_JOBS_LEGACY\n"
MESSAGE+="$REPO_NAME_CURRENT: $NUMBER_OF_PULL_REPO_JOBS_CURRENT"

# Send the message to Slack
curl -X POST -H 'Content-type: application/json' --data "{\"message\":\"$MESSAGE\"}" "$SLACK_WEBHOOK_URL"
