---
name: tracker-issue-status-report-generate
description: Generate status reports for all tracking issues in telco-bot repo, create gists, and comment on issues
allowed-tools:
  - Bash(gh issue list:*)
  - Bash(gh issue view:*)
  - Bash(gh issue comment:*)
  - Bash(gh pr list:*)
  - Bash(gh pr view:*)
  - Bash(gh api:*)
  - Bash(gh gist create:*)
  - Bash(gh gist edit:*)
  - Bash(cat:*)
  - mcp__github__list_issues
  - mcp__github__issue_read
  - mcp__github__add_issue_comment
  - mcp__github__pull_request_read
  - Skill(highlight)
---

# Tracker Issue Status Report Generator

Generate comprehensive status reports for all tracking issues in the telco-bot repository, create GitHub gists with the reports, and post/update comments on each tracking issue.

## Tracking Issues

The following tracking issues are monitored in `redhat-best-practices-for-k8s/telco-bot`:

| Issue | Topic | Script |
|-------|-------|--------|
| #59 | golang.org/x/crypto Direct Usage | xcrypto-lookup.sh |
| #52 | Deprecated io/ioutil Package Usage | ioutil-deprecation-checker.sh |
| #49 | Outdated GolangCI-Lint Versions | golangci-lint-checker.sh |
| #45 | Deprecated golang/mock Usage | gomock-lookup.sh |
| #39 | Out of Date Golang Versions | go-version-checker.sh |

## Workflow

### 1. Fetch All Tracking Issues

```bash
gh issue list --repo redhat-best-practices-for-k8s/telco-bot --state open --json number,title,body
```

Filter for issues with titles starting with "Tracking".

### 2. For Each Tracking Issue

#### a) Parse the Issue Body

Extract from the issue body:
- List of affected repositories
- Current versions/status for each repo
- Links to any tracking issues in those repos
- Links to any open PRs

#### b) Verify Repository Status

For each listed repository, verify the current state:

**For x/crypto (#59):**
```bash
gh api repos/<org>/<repo>/contents/go.mod --jq '.content' | base64 -d | grep 'golang.org/x/crypto'
```

**For io/ioutil (#52):**
- Check if PRs are merged, open, or closed
```bash
gh pr view <pr-number> --repo <repo> --json state,mergeable,mergeStateStatus
```

**For golangci-lint (#49):**
```bash
gh api repos/<org>/<repo>/contents/Makefile --jq '.content' | base64 -d | grep -i golangci
```

**For golang/mock (#45):**
- Check PR status for migration PRs
```bash
gh pr view <pr-number> --repo <repo> --json state,mergeable,mergeStateStatus
```

**For Go versions (#39):**
```bash
gh api repos/<org>/<repo>/contents/go.mod --jq '.content' | base64 -d | grep "^go "
```

#### c) Check Tracking Issues in Target Repos

For repos with tracking issues, check their status:
```bash
gh issue view <issue-number> --repo <target-repo> --json state,comments
```

#### d) Check Open PRs

For repos with open PRs:
```bash
gh pr view <pr-number> --repo <repo> --json state,mergeable,mergeStateStatus,reviewDecision
```

### 3. Generate Status Report

Create a markdown report for each tracking issue with:

```markdown
# <Topic> Status Report

**Report Date:** YYYY-MM-DD
**Central Tracking Issue:** [link]

## Executive Summary
- Total repositories affected: X
- Tracking issues created: X
- PRs merged: X
- PRs open: X
- PRs needing attention: X

## Verified Repository Status

### Priority/Critical Items
[Table of high-priority items]

### Standard Items
[Table of remaining items]

## PR Status Overview

### Merged PRs
[Table]

### Open PRs - Ready to Merge
[Table with merge state]

### Open PRs - Need Attention
[Table with issues]

### Closed PRs
[Table]

## Recommendations
1. ...
2. ...

---
*Report generated on YYYY-MM-DD*
```

### 4. Create/Update Gist

For each report:

**Check for existing gist from today:**
```bash
gh gist list --limit 50 | grep "<topic>-status-report"
```

**Create new gist:**
```bash
gh gist create /tmp/<topic>-status-report.md --desc "<Topic> Status Report - YYYY-MM-DD" --public
```

**Or update existing:**
```bash
gh gist edit <gist-id> --add /tmp/<topic>-status-report.md
```

### 5. Post/Update Comment on Tracking Issue

**Check for existing comment from today:**
Look for comments containing "Status Report - YYYY-MM-DD" from the bot user.

**If comment exists, update it:**
Use GitHub API to update the comment.

**If no comment, create new:**
```bash
gh issue comment <issue-number> --repo redhat-best-practices-for-k8s/telco-bot --body "<comment>"
```

### 6. Summary Output

After processing all issues, output a summary and store the gist URLs for the highlight:

```markdown
## Tracker Status Report Generation Complete

| Issue | Topic | Gist | Comment |
|-------|-------|------|---------|
| #59 | x/crypto | [link] | [link] |
| #52 | io/ioutil | [link] | [link] |
| #49 | golangci-lint | [link] | [link] |
| #45 | golang/mock | [link] | [link] |
| #39 | Go versions | [link] | [link] |

Generated: YYYY-MM-DD HH:MM:SS UTC
```

### 7. Generate Highlight

After completing all reports, automatically invoke the `/highlight` skill to create a work highlight.

**Context to provide for the highlight:**
- Number of tracking issues processed
- Number of repositories verified
- Key findings (critical CVEs, stale PRs, etc.)
- Links to all generated gists

**The highlight should include links to:**
1. The tracking issues list: `https://github.com/redhat-best-practices-for-k8s/telco-bot/issues?q=is%3Aissue+is%3Aopen+Tracking`
2. Each generated gist report

**Example highlight format:**
```markdown
## YYYY-MM-DD: Dependency Tracking Status Reports

Generated verified status reports for 5 tracking initiatives across 100+ repositories.
Key findings: [summary of critical items]. Reports:
[x/crypto](gist-url) | [io/ioutil](gist-url) | [golangci-lint](gist-url) | [golang/mock](gist-url) | [Go versions](gist-url)
```

**Invoke the highlight skill:**
```
/highlight
```

Provide the context above so the highlight accurately captures the work completed and includes all report links.

## Comment Format

Each comment should follow this template:

```markdown
## 📊 <Topic> Status Report - YYYY-MM-DD

A detailed analysis of <topic> has been completed.

### Key Findings

- **X repositories** affected
- **X PRs merged** / **X PRs open** / **X PRs closed**
- [Key insight 1]
- [Key insight 2]

### Status Summary

| Status | Count |
|--------|-------|
| Merged | X |
| Open (Mergeable) | X |
| Open (Conflicting) | X |
| Closed | X |
| No PR | X |

### Full Report

📄 **[View the complete status report](<gist-url>)**

---
*Report generated via automated verification on YYYY-MM-DD.*
```

## Usage

```
/tracker-issue-status-report-generate
```

This will:
1. Process all 5 tracking issues
2. Verify current repository states
3. Generate detailed reports
4. Create/update gists
5. Post/update comments on each issue
6. Automatically generate a `/highlight` with links to all reports

## Notes

- Reports are date-stamped to track when verification was performed
- Existing comments from the same day are updated rather than duplicated
- Gists are public for easy sharing
- The workflow respects GitHub API rate limits through the `gh` CLI
- All data is verified against live repository state, not cached values

## Error Handling

- If a repository is inaccessible, note it in the report
- If a PR check fails, include the error in the status
- Continue processing other items even if one fails
- Report any errors in the summary output
