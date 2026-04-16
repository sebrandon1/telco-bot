#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/slack.sh"

if [ -z "$XCRYPTO_SLACK_WEBHOOK" ]; then
	echo -e "${YELLOW}XCRYPTO_SLACK_WEBHOOK not set, skipping Slack notification${RESET}"
	exit 0
fi

if [ "$#" -lt 5 ]; then
	echo -e "${RED}ERROR: Missing required arguments${RESET}"
	echo ""
	echo "Usage: $0 <total_repos> <org_count> <outdated_count> <found_count> <tracking_issue_url>"
	exit 1
fi

TOTAL_REPOS="$1"
ORG_COUNT="$2"
OUTDATED_COUNT="$3"
FOUND_COUNT="$4"
TRACKING_ISSUE_URL="$5"

echo -e "${BLUE}${BOLD}Sending Slack Notification${RESET}"
echo -e "   Total repos scanned: ${TOTAL_REPOS}"
echo -e "   Organizations: ${ORG_COUNT}"
echo -e "   Repos using x/crypto: ${FOUND_COUNT}"
echo -e "   Outdated repos: ${OUTDATED_COUNT}"
echo -e "   Tracking issue: ${TRACKING_ISSUE_URL}"

if [ "$FOUND_COUNT" -gt 0 ]; then
	OUTDATED_PCT=$(awk "BEGIN {printf \"%.0f\", ($OUTDATED_COUNT / $FOUND_COUNT) * 100}")
else
	OUTDATED_PCT=0
fi

if [ "$OUTDATED_COUNT" -eq 0 ]; then
	STATUS_LINE=":white_check_mark: All ${FOUND_COUNT} repos using x/crypto are up to date! No action needed."
elif [ "$OUTDATED_COUNT" -lt 5 ]; then
	STATUS_LINE=":warning: ${OUTDATED_COUNT} repos need attention — running outdated versions of x/crypto (${OUTDATED_PCT}% of users)"
else
	STATUS_LINE=":rotating_light: ${OUTDATED_COUNT} repos are running outdated x/crypto versions! (${OUTDATED_PCT}% of users)

Keeping crypto libraries current is critical for security. Please review and prioritize updates."
fi

MESSAGE=":lock: x/crypto Weekly Security Scan
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

:mag: Scanned ${TOTAL_REPOS} repositories across ${ORG_COUNT} organizations
:package: ${FOUND_COUNT} repos using x/crypto directly

${STATUS_LINE}

:page_facing_up: Full report: ${TRACKING_ISSUE_URL}"

echo
if send_slack_message "$XCRYPTO_SLACK_WEBHOOK" "$MESSAGE"; then
	echo -e "${GREEN}${BOLD}Slack notification sent successfully!${RESET}"
else
	echo -e "${RED}${BOLD}Failed to send Slack notification${RESET}"
	exit 1
fi
