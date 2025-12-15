#!/bin/bash

#===============================================================================
# XCRYPTO SLACK NOTIFICATION SCRIPT
#===============================================================================
#
# DESCRIPTION:
#   Sends a Slack notification with x/crypto scan results.
#   Can be run standalone for testing or called from xcrypto-lookup.sh.
#
# PREREQUISITES:
#   1. curl and jq must be installed
#   2. XCRYPTO_SLACK_WEBHOOK environment variable must be set
#
# USAGE:
#   # Set required environment variable
#   export XCRYPTO_SLACK_WEBHOOK="https://hooks.slack.com/triggers/..."
#
#   # Run with arguments
#   ./xcrypto-slack.sh <total_repos> <org_count> <outdated_count> <found_count> <tracking_issue_url>
#
#   # Example:
#   ./xcrypto-slack.sh 500 5 12 25 "https://github.com/redhat-best-practices-for-k8s/telco-bot/issues/42"
#
# TESTING LOCALLY:
#   export XCRYPTO_SLACK_WEBHOOK="your-webhook-url"
#   ./scripts/xcrypto-slack.sh 100 3 5 10 "https://github.com/redhat-best-practices-for-k8s/telco-bot/issues/1"
#
#===============================================================================

# Terminal colors
GREEN="\033[0;32m"
RED="\033[0;31m"
BLUE="\033[0;34m"
YELLOW="\033[0;33m"
BOLD="\033[1m"
RESET="\033[0m"

# Check if XCRYPTO_SLACK_WEBHOOK is set
if [ -z "$XCRYPTO_SLACK_WEBHOOK" ]; then
	echo -e "${YELLOW}⚠️  XCRYPTO_SLACK_WEBHOOK not set, skipping Slack notification${RESET}"
	exit 0
fi

# Check dependencies
for cmd in curl jq; do
	if ! command -v $cmd &>/dev/null; then
		echo -e "${RED}❌ ERROR: $cmd is required but not installed${RESET}"
		exit 1
	fi
done

# Validate arguments
if [ "$#" -lt 5 ]; then
	echo -e "${RED}❌ ERROR: Missing required arguments${RESET}"
	echo ""
	echo "Usage: $0 <total_repos> <org_count> <outdated_count> <found_count> <tracking_issue_url>"
	echo ""
	echo "Arguments:"
	echo "  total_repos        - Total number of repositories scanned"
	echo "  org_count          - Number of organizations scanned"
	echo "  outdated_count     - Number of repos with outdated x/crypto versions"
	echo "  found_count        - Number of repos using x/crypto directly"
	echo "  tracking_issue_url - URL to the tracking issue"
	echo ""
	echo "Example:"
	echo "  $0 500 5 12 25 \"https://github.com/redhat-best-practices-for-k8s/telco-bot/issues/42\""
	exit 1
fi

# Collect arguments
TOTAL_REPOS="$1"
ORG_COUNT="$2"
OUTDATED_COUNT="$3"
FOUND_COUNT="$4"
TRACKING_ISSUE_URL="$5"

echo -e "${BLUE}${BOLD}📤 Sending Slack Notification${RESET}"
echo -e "${BLUE}─────────────────────────────────────────────────────${RESET}"
echo -e "   Total repos scanned: ${TOTAL_REPOS}"
echo -e "   Organizations: ${ORG_COUNT}"
echo -e "   Repos using x/crypto: ${FOUND_COUNT}"
echo -e "   Outdated repos: ${OUTDATED_COUNT}"
echo -e "   Tracking issue: ${TRACKING_ISSUE_URL}"
echo

# Build the message (plain text - Slack Workflow webhooks don't support mrkdwn)
# Customize message based on outdated count
if [ "$OUTDATED_COUNT" -eq 0 ]; then
	# All repos are up to date! 🎉
	MESSAGE="🔐 x/crypto Weekly Scan Complete ✅

🔍 Scanned ${TOTAL_REPOS} repositories across ${ORG_COUNT} organizations

🎉 Great news! All ${FOUND_COUNT} repos using x/crypto are up to date. No action needed!

📋 Full report: ${TRACKING_ISSUE_URL}"
elif [ "$OUTDATED_COUNT" -lt 5 ]; then
	# Small number of outdated repos
	MESSAGE="🔐 x/crypto Weekly Scan Complete

🔍 Scanned ${TOTAL_REPOS} repositories across ${ORG_COUNT} organizations

⚠️ ${OUTDATED_COUNT} repos need attention — they're running outdated versions of x/crypto and should be updated for security.

📋 View the full breakdown: ${TRACKING_ISSUE_URL}"
else
	# Larger number of outdated repos - more urgent tone
	MESSAGE="🔐 x/crypto Weekly Scan Complete

🔍 Scanned ${TOTAL_REPOS} repositories across ${ORG_COUNT} organizations

🚨 ${OUTDATED_COUNT} repos are running outdated versions of x/crypto and need to be updated!

Keeping crypto libraries current is critical for security. Please review and prioritize updates.

📋 Tracking issue: ${TRACKING_ISSUE_URL}"
fi

# Construct Slack payload with 'message' field (matching webhook config)
PAYLOAD=$(jq -n --arg message "$MESSAGE" '{message: $message}')

echo -e "   ${BLUE}Message:${RESET}"
echo -e "   $MESSAGE"
echo

# Send to Slack
echo -ne "   Sending to Slack... "
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST -H 'Content-type: application/json' --data "$PAYLOAD" "$XCRYPTO_SLACK_WEBHOOK")

# Extract HTTP status code (last line) and response body
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
RESPONSE_BODY=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_CODE" = "200" ]; then
	echo -e "${GREEN}✅ Success${RESET}"
	echo -e "${GREEN}${BOLD}✅ Slack notification sent successfully!${RESET}"
else
	echo -e "${RED}❌ Failed (HTTP $HTTP_CODE)${RESET}"
	echo -e "${RED}   Response: $RESPONSE_BODY${RESET}"
	exit 1
fi
