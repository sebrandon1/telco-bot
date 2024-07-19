#!/bin/bash

SLACK_WEBHOOK_URL=$1
JSON_FILE=$2
START_DATE=$3
END_DATE=$4

# Loop through the JSON file and add up the number of jobs with 'kind: pull_repo' and adding up the 'count' value
NUMBER_OF_PULL_REPO_JOBS=$(cat $JSON_FILE | jq '.aggregated[] | select(.kind == "pull_repo") | .count' | awk '{s+=$1} END {print s}')

MESSAGE="The cnf-certification-test image repo has been pulled from $NUMBER_OF_PULL_REPO_JOBS times between $START_DATE and $END_DATE."

# Send the message to Slack
curl -X POST -H 'Content-type: application/json' --data "{\"message\":\"$MESSAGE\"}" $SLACK_WEBHOOK_URL
