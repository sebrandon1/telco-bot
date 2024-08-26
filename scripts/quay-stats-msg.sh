#!/bin/bash

SLACK_WEBHOOK_URL=$1
JSON_FILE_LEGACY=$2
JSON_FILE_CURRENT=$3
START_DATE=$4
END_DATE=$5
REPO_NAME_LEGACY=$6
REPO_NAME_CURRENT=$7

# Loop through the JSON file and add up the number of jobs with 'kind: pull_repo' and adding up the 'count' value
NUMBER_OF_PULL_REPO_JOBS_LEGACY=$(cat $JSON_FILE_LEGACY | jq '.aggregated[] | select(.kind == "pull_repo") | .count' | awk '{s+=$1} END {print s}')
NUMBER_OF_PULL_REPO_JOBS_CURRENT=$(cat $JSON_FILE_CURRENT | jq '.aggregated[] | select(.kind == "pull_repo") | .count' | awk '{s+=$1} END {print s}')

TOTAL_PULL_REPO_JOBS=$(($NUMBER_OF_PULL_REPO_JOBS_LEGACY + $NUMBER_OF_PULL_REPO_JOBS_CURRENT))

MESSAGE="The following images have been pulled $TOTAL_PULL_REPO_JOBS times between $START_DATE and $END_DATE:\n\n"

MESSAGE+="$REPO_NAME_LEGACY: $NUMBER_OF_PULL_REPO_JOBS_LEGACY\n"
MESSAGE+="$REPO_NAME_CURRENT: $NUMBER_OF_PULL_REPO_JOBS_CURRENT"

# Send the message to Slack
curl -X POST -H 'Content-type: application/json' --data "{\"message\":\"$MESSAGE\"}" $SLACK_WEBHOOK_URL
