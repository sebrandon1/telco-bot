#!/bin/bash

SEMVER_REGEX="^v[0-9]+\.[0-9]+\.[0-9]+$"

# Collect the arguments
SLACK_WEBHOOK_URL=$1
JSON_FILE=$2
OCP_VERSION_FILE=$3
DAYS_BACK=$4

NUMBER_OF_RECORDS=$(cat $JSON_FILE | jq '.jobs | length')

RUNS_BY_COMMIT_CTR=0

MESSAGE="There have been $NUMBER_OF_RECORDS DCI jobs that have used the certsuite in the last $DAYS_BACK days.\n"

VERSIONS_BY_VALUE=$(cat $JSON_FILE | jq '.jobs | group_by(.tnf_version) | map({key: .[0].tnf_version, value: length})')

for row in $(echo "${VERSIONS_BY_VALUE}" | jq -r '.[] | @base64'); do
    _jq() {
        echo ${row} | base64 --decode | jq -r ${1}
    }

    # echo "Evaluating key: $(_jq '.key') $RUNS_BY_COMMIT_CTR"

    # Check if the version matches the semver regex
    if [[ ! $(_jq '.key') =~ $SEMVER_REGEX ]]; then
        let "RUNS_BY_COMMIT_CTR=RUNS_BY_COMMIT_CTR+$(_jq '.value')"
    else
        VERSION=$(_jq '.key')
        COUNT=$(_jq '.value')

        MESSAGE="$MESSAGE\n Version: $VERSION -- Run Count: $COUNT"
    fi
done

if [ $RUNS_BY_COMMIT_CTR -gt 0 ]; then
    MESSAGE="$MESSAGE\n\nThere have been $RUNS_BY_COMMIT_CTR runs by commit hash."
fi

# Use jq to verify OCP_VERSION_FILE is valid JSON
jq . $OCP_VERSION_FILE

if [ $? -ne 0 ]; then
    echo "The OCP_VERSION_FILE is not valid JSON. Exiting."
    exit 1
fi

MESSAGE="$MESSAGE\n\nThe following OCP versions have been tested against in the last $DAYS_BACK days:"

for row in $(cat $OCP_VERSION_FILE | jq -r '.ocp_versions[] | @base64'); do
    _jq() {
        echo ${row} | base64 --decode | jq -r ${1}
    }

    # Skip any counts that are 0
    if [ $(_jq '.run_count') -eq 0 ]; then
        continue
    fi

    VERSION=$(_jq '.ocp_version')
    COUNT=$(_jq '.run_count')

    MESSAGE="$MESSAGE\nOCP Version: $VERSION -- Run Count: $COUNT"
done

echo $MESSAGE

DATA="{\"message\"   : \"${MESSAGE}\"}"

# Send the message to Slack
curl -X POST -H 'Content-type: application/json charset=UTF-8' --data "$DATA" $SLACK_WEBHOOK_URL

