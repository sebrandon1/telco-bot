#!/bin/bash

# Slack Incoming Webhook URL
SLACK_WEBHOOK_URL=$2
JSON_FILE=$3
DAYS_BACK=$4

NUMBER_OF_RECORDS=$(cat $JSON_FILE | jq '.jobs | length')

MESSAGE="There have been $NUMBER_OF_RECORDS DCI jobs in the last $DAYS_BACK days.\n"

