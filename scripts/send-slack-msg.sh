#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/slack.sh"

SEMVER_REGEX="^v[0-9]+\.[0-9]+\.[0-9]+$"

_jq() {
	echo "${1}" | base64 --decode | jq -r "${2}"
}

if [ "$#" -lt 4 ]; then
	echo "Usage: $0 <SLACK_WEBHOOK_URL> <JSON_FILE> <OCP_VERSION_FILE> <DAYS_BACK>"
	exit 1
fi

SLACK_WEBHOOK_URL=$1
JSON_FILE=$2
OCP_VERSION_FILE=$3
DAYS_BACK=$4

validate_json "$JSON_FILE" || exit 1
validate_json "$OCP_VERSION_FILE" || exit 1

NUMBER_OF_RECORDS=$(jq '.jobs | length' "$JSON_FILE")
RUNS_BY_COMMIT_CTR=0

VERSIONS_BY_VALUE=$(jq '.jobs | group_by(.certsuite_version) | map({key: .[0].certsuite_version, value: length}) | sort_by(.key) | reverse' "$JSON_FILE")

VERSION_LINES=""
for row in $(echo "$VERSIONS_BY_VALUE" | jq -r '.[] | @base64'); do
	if [[ ! $(_jq "$row" '.key') =~ $SEMVER_REGEX ]]; then
		RUNS_BY_COMMIT_CTR=$((RUNS_BY_COMMIT_CTR + $(_jq "$row" '.value')))
	else
		VERSION=$(_jq "$row" '.key')
		COUNT=$(_jq "$row" '.value')
		VERSION_LINES="${VERSION_LINES}   ${VERSION}  —  ${COUNT} runs
"
	fi
done

OCP_LINES=""
for row in $(jq -r '.ocp_versions[] | @base64' "$OCP_VERSION_FILE"); do
	if [ "$(_jq "$row" '.run_count')" -eq 0 ]; then
		continue
	fi
	VERSION=$(_jq "$row" '.ocp_version')
	COUNT=$(_jq "$row" '.run_count')
	OCP_LINES="${OCP_LINES}   ${VERSION}  —  ${COUNT} runs
"
done

MESSAGE=":bar_chart: Certsuite DCI Weekly Report
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

:hash: ${NUMBER_OF_RECORDS} DCI jobs used the certsuite in the last ${DAYS_BACK} days
"

if [ -n "$VERSION_LINES" ]; then
	MESSAGE="${MESSAGE}
:package: Runs by Release Version:
${VERSION_LINES}"
fi

if [ $RUNS_BY_COMMIT_CTR -gt 0 ]; then
	MESSAGE="${MESSAGE}:wrench: ${RUNS_BY_COMMIT_CTR} runs by commit hash
"
fi

MESSAGE="${MESSAGE}
:desktop_computer: OCP Versions Tested:
${OCP_LINES}"

echo "$MESSAGE"
send_slack_message "$SLACK_WEBHOOK_URL" "$MESSAGE"
