#!/bin/bash
#===============================================================================
# SLACK NOTIFICATION LIBRARY FOR TELCO-BOT
#===============================================================================
#
# Shared functions for building and sending Slack messages via Workflow webhooks.
# Source this file from notification scripts:
#
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/lib/slack.sh"
#
# Requires: curl, jq
#===============================================================================

# Send a plain text message to a Slack Workflow webhook.
# Usage: send_slack_message "$WEBHOOK_URL" "$MESSAGE" ["message"|"text"]
# The third argument is the JSON field name (defaults to "message").
send_slack_message() {
	local webhook_url="$1"
	local message="$2"
	local field_name="${3:-message}"

	local payload
	payload=$(jq -n --arg msg "$message" --arg field "$field_name" '{($field): $msg}')

	local response http_code response_body
	response=$(curl -s -w "\n%{http_code}" -X POST -H 'Content-type: application/json' --data "$payload" "$webhook_url")
	http_code=$(echo "$response" | tail -n1)
	response_body=$(echo "$response" | sed '$d')

	if [ "$http_code" = "200" ]; then
		echo "Slack message sent successfully"
		return 0
	else
		echo "ERROR: Slack send failed (HTTP $http_code): $response_body" >&2
		return 1
	fi
}

# Validate that a file contains valid JSON
validate_json() {
	local file="$1"
	if ! jq empty "$file" 2>/dev/null; then
		echo "ERROR: Invalid JSON in $file" >&2
		return 1
	fi
}
