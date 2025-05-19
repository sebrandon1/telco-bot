#!/bin/bash

# Usage: ./sanitize-raw-jira-format.sh <input_json_file> <output_json_file>
# Requires: jq

set -e

if [[ $# -ne 2 ]]; then
	echo "Usage: $0 <input_json_file> <output_json_file>"
	exit 1
fi

INPUT_FILE="$1"
OUTPUT_FILE="$2"

jq -r '[.[] | .issues[] 
  | select(.fields.assignee != null) 
  | select(.fields.status.name != "Closed")
  | {
      name: .fields.assignee.displayName, 
      email: .fields.assignee.emailAddress,
      issue: {
          key: .key, 
          summary: .fields.summary,
          status: .fields.status.name, 
          priority: .fields.priority.name,
          created: .fields.created,
          updated: .fields.updated, 
          url: ("https://issues.redhat.com/browse/" + .key), 
          fixVersion: (.fields.fixVersions[0].name // "none")
      }
  }] | group_by(.name) | map({user: .[0].name, email: .[0].email, issues: map(.issue)})' "$INPUT_FILE" >"$OUTPUT_FILE"
