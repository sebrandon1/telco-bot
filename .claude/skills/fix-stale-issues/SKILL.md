---
name: fix-stale-issues
description: Remove lifecycle/stale label from tracking issues linked in telco-bot tracking issues
argument-hint: "[issue-number]"
allowed-tools:
  - Bash(gh api:*)
  - Bash(gh issue view:*)
  - Bash(gh issue list:*)
  - mcp__github__issue_read
  - mcp__github__add_issue_comment
  - mcp__github__list_issues
---

# Fix Stale Issues

Find and remove the `lifecycle/stale` label from tracking issues linked in telco-bot tracking issues by commenting `/remove-lifecycle stale`.

**Target Issue:** "$ARGUMENTS" (defaults to all open tracking issues if not specified)

## Workflow

### 1. Identify Target Tracking Issues

- If "$ARGUMENTS" is provided as an issue number, use that single issue from `redhat-best-practices-for-k8s/telco-bot`
- Otherwise, list all open issues in `redhat-best-practices-for-k8s/telco-bot` and process each one that contains a tracking table with linked issues

Known tracking issues:
- `#39` - Tracking Out of Date Golang Versions
- Other tracking issues may exist; scan all open issues for linked issue tables

### 2. Extract Linked Issues

For each tracking issue, read the issue body and extract all GitHub issue URLs matching the pattern:
```
https://github.com/<owner>/<repo>/issues/<number>
```

These are found in the "Tracking Issue" column of the markdown tables in the issue body.

### 3. Check Each Linked Issue for Stale Label

For each extracted issue URL:

1. Parse out the `owner`, `repo`, and `issue_number`
2. Fetch the issue via `gh api repos/<owner>/<repo>/issues/<number>`
3. Check if the issue is **open** AND has the `lifecycle/stale` label
4. Skip issues that are already **closed** or don't have the stale label

### 4. Comment to Remove Stale Label

For each issue that is open and has `lifecycle/stale`:
- Comment `/remove-lifecycle stale` on the issue using the GitHub MCP tool (`mcp__github__add_issue_comment`)
- This triggers the Prow bot to remove the `lifecycle/stale` label

### 5. Generate Report

Present results in a summary table:

```markdown
## Stale Issues Fixed

**Tracking Issue:** #<number> - <title>
**Total Linked Issues:** X
**Open Issues:** X
**Stale Issues Found:** X
**Already Closed:** X

### Issues Updated

| Repository | Issue | Status |
|---|---|---|
| `owner/repo` | [#N](url) | Commented `/remove-lifecycle stale` |

### Already Closed (no action needed)

| Repository | Issue |
|---|---|
| `owner/repo` | [#N](url) |

### Open & Healthy (no stale label)

X issues had no stale label and needed no action.
```

## Usage Examples

**Fix stale issues in tracking issue #39:**
```
/fix-stale-issues 39
```

**Fix stale issues across all tracking issues:**
```
/fix-stale-issues
```

## Notes

- Only comments on issues that are **open** and have the `lifecycle/stale` label
- Closed issues are skipped entirely
- The `/remove-lifecycle stale` comment is processed by Prow/lifecycle bot to remove the label
- Rate limiting: processes issues sequentially to avoid GitHub API rate limits
- The script checks all organizations: `openshift`, `openshift-kni`, `redhat-openshift-ecosystem`, `redhatci`
