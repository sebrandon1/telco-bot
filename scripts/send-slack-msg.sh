#!/bin/bash

# Slack Incoming Webhook URL
SLACK_WEBHOOK_URL=$1
JSON_FILE=$2
DAYS_BACK=$3

NUMBER_OF_RECORDS=$(cat $JSON_FILE | jq '.jobs | length')

MESSAGE="There have been $NUMBER_OF_RECORDS DCI jobs in the last $DAYS_BACK days."

echo $MESSAGE

DATA="{\"message\"   : \"${MESSAGE}\"}"

# Send the message to Slack
curl -X POST -H 'Content-type: application/json charset=UTF-8' --data "$DATA" $SLACK_WEBHOOK_URL
