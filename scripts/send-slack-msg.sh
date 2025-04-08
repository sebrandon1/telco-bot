#!/bin/bash

SEMVER_REGEX="^v[0-9]+\.[0-9]+\.[0-9]+$"

# Function to validate required tools
dependencies_check() {
	for cmd in jq curl; do
		if ! command -v $cmd &>/dev/null; then
			echo "$cmd is required but not installed. Exiting."
			exit 1
		fi
	done
}

# Function to decode base64 and extract JSON fields
_jq() {
	echo ${1} | base64 --decode | jq -r ${2}
}

# Validate arguments
if [ "$#" -lt 4 ]; then
	echo "Usage: $0 <SLACK_WEBHOOK_URL> <JSON_FILE> <OCP_VERSION_FILE> <DAYS_BACK>"
	exit 1
fi

# Collect the arguments
SLACK_WEBHOOK_URL=$1
JSON_FILE=$2
OCP_VERSION_FILE=$3
DAYS_BACK=$4

# Check dependencies
dependencies_check

NUMBER_OF_RECORDS=$(jq '.jobs | length' "$JSON_FILE")

RUNS_BY_COMMIT_CTR=0

MESSAGE="There have been $NUMBER_OF_RECORDS DCI jobs that have used the certsuite in the last $DAYS_BACK days.\n"

VERSIONS_BY_VALUE=$(jq '.jobs | group_by(.certsuite_version) | map({key: .[0].certsuite_version, value: length})' "$JSON_FILE")

for row in $(echo "$VERSIONS_BY_VALUE" | jq -r '.[] | @base64'); do
	# Check if the version matches the semver regex
	if [[ ! $(_jq "$row" '.key') =~ $SEMVER_REGEX ]]; then
		let "RUNS_BY_COMMIT_CTR=RUNS_BY_COMMIT_CTR+$(_jq "$row" '.value')"
	else
		VERSION=$(_jq "$row" '.key')
		COUNT=$(_jq "$row" '.value')

		MESSAGE="$MESSAGE\n Version: $VERSION -- Run Count: $COUNT"
	fi
done

if [ $RUNS_BY_COMMIT_CTR -gt 0 ]; then
	MESSAGE="$MESSAGE\n\nThere have been $RUNS_BY_COMMIT_CTR runs by commit hash."
fi

# Use jq to verify OCP_VERSION_FILE is valid JSON
if ! jq . "$OCP_VERSION_FILE" &>/dev/null; then
	echo "The OCP_VERSION_FILE is not valid JSON. Exiting."
	exit 1
fi

MESSAGE="$MESSAGE\n\nThe following OCP versions have been tested against in the last $DAYS_BACK days:"

for row in $(jq -r '.ocp_versions[] | @base64' "$OCP_VERSION_FILE"); do
	# Skip any counts that are 0
	if [ $(_jq "$row" '.run_count') -eq 0 ]; then
		continue
	fi

	VERSION=$(_jq "$row" '.ocp_version')
	COUNT=$(_jq "$row" '.run_count')

	MESSAGE="$MESSAGE\nOCP Version: $VERSION -- Run Count: $COUNT"
done

echo "$MESSAGE"

DATA="{\"message\"   : \"${MESSAGE}\"}"

# Send the message to Slack
curl -X POST -H 'Content-type: application/json charset=UTF-8' --data "$DATA" "$SLACK_WEBHOOK_URL"
