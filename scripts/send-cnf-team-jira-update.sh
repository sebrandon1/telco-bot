#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/slack.sh"

if [[ $# -lt 2 ]]; then
	echo "Usage: $0 <slack_webhook_url> <json_file>"
	exit 1
fi

SLACK_WEBHOOK_URL="$1"
JSON_FILE="$2"

validate_json "$JSON_FILE" || exit 1

TOTAL_ISSUES=$(jq '[.[] | .issues | length] | add // 0' "$JSON_FILE")
MEMBER_COUNT=$(jq 'length' "$JSON_FILE")

FIXVER_SUMMARY=$(jq -r '
  [.[] | .issues[]] | group_by(.fixVersion)
  | map({v: .[0].fixVersion, c: length})
  | sort_by(.c) | reverse
  | map("   " + (if .v == "none" then "No Fix Version" else .v end) + ": " + (.c | tostring) + " issues")
  | join("\n")
' "$JSON_FILE")

USER_SECTIONS=$(jq -r '.[] |
  ":bust_in_silhouette: " + .user + " (" + (.issues | length | tostring) + " issues):\n" +
  (.issues | sort_by(.updated) | map(
    "   " + .url + " (" + (if .fixVersion == "none" then "No Fix Version" else .fixVersion end) + ") — " + .status + " — Updated: " + (.updated | split("T")[0])
  ) | join("\n")) + "\n"
' "$JSON_FILE")

MESSAGE=":clipboard: CNF Team Jira Weekly Update
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

:busts_in_silhouette: Team Members: ${MEMBER_COUNT}
:ticket: Open Issues: ${TOTAL_ISSUES}

:bar_chart: Issues by Fix Version:
${FIXVER_SUMMARY}

${USER_SECTIONS}"

send_slack_message "$SLACK_WEBHOOK_URL" "$MESSAGE" "text"
