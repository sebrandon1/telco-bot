#!/bin/bash

# Usage: ./send-cnf-team-jira-update.sh <slack_webhook_url> <json_file>
# Requires: jq, curl

set -e

if [[ $# -lt 2 ]]; then
	echo "Usage: $0 <slack_webhook_url> <json_file>"
	exit 1
fi

SLACK_WEBHOOK_URL="$1"
JSON_FILE="$2"

# Build the Slack message content
MESSAGE=$(jq -r '
  def fixver_counts:
    [ .[] | .issues[] | {fixVersion} ]
    | group_by(.fixVersion)
    | map({fixVersion: .[0].fixVersion, count: length});

  def fixver_summary:
    fixver_counts
    | map("- " + (if .fixVersion == "none" then "No Fix Version" else .fixVersion end) + ": " + (.count | tostring) + " issues")
    | join("\n");

  ([ .[] |
    (.user + " (" + ((.issues | length | tostring)) + " issues assigned):\n") +
    (
      if ((.issues // []) | type) != "array" or ((.issues // []) | length) == 0 then
        "  - No issues"
      else
        (.issues | map(
          .url + " (" + (if .fixVersion == "none" then "No Fix Version" else .fixVersion end) + ") - Status: " + .status + " - Last Updated: " + (.updated | split("T")[0])
        ) | join("\n"))
      end
    )
  ] | join("\n")) +
  "\n\nTeam Issue Totals by Fix Version:\n" + fixver_summary
' "$JSON_FILE")

# Construct the Slack payload for Workflow webhooks (text only)
payload=$(jq -n --arg text "$MESSAGE" '{text: $text}')

# Send to Slack
curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK_URL"
