---
name: pr-checkup
description: Check on PRs linked in repository issues for reviews, rebases, or failing CIs
argument-hint: "[repo-owner/repo-name]"
allowed-tools:
  - Bash(gh issue list:*)
  - Bash(gh issue view:*)
  - Bash(gh pr list:*)
  - Bash(gh pr view:*)
  - Bash(gh pr checks:*)
  - Bash(gh api:*)
  - mcp__github__list_issues
  - mcp__github__pull_request_read
  - mcp__github__search_pull_requests
---

# PR Checkup

Scan repository issues for linked PRs and check their status for items needing attention.

**Target Repository:** "$ARGUMENTS" (defaults to current repo if not specified)

## Workflow

### 1. Identify Target Repository

- If "$ARGUMENTS" is provided, use that as the target repo (e.g., `redhat-best-practices-for-k8s/certsuite`)
- Otherwise, detect the current repository from git remote

### 2. Fetch Open Issues

Run: `gh issue list --repo <target-repo> --state open --limit 100 --json number,title,body,labels`

### 3. Extract PR Links from Issues

For each issue, scan the body for:
- GitHub PR URLs: `https://github.com/<owner>/<repo>/pull/<number>`
- PR references: `#<number>` (same repo) or `<owner>/<repo>#<number>` (cross-repo)
- Keywords indicating PR links: "PR", "pull request", "fixes", "closes"

### 4. Check Each Linked PR

For each discovered PR, gather status using `gh pr view`:

**a) Review Status:**
- Check `reviewDecision`: APPROVED, CHANGES_REQUESTED, REVIEW_REQUIRED, or no reviews
- Count pending review requests
- Identify if reviews are stale (code pushed after approval)

**b) Rebase/Merge Status:**
- Check `mergeStateStatus`: BEHIND, BLOCKED, CLEAN, DIRTY, UNKNOWN
- Check if PR is mergeable or needs rebase
- Check for merge conflicts

**c) CI/Check Status:**
- Run `gh pr checks <pr-number> --repo <repo>` to get CI status
- Identify: PASS, FAIL, PENDING, or SKIPPED checks
- Note any required checks that are failing

### 5. Generate Report

Organize findings into actionable categories:

```markdown
# PR Checkup Report

## Summary
- Issues scanned: X
- PRs found: X
- PRs needing attention: X

## Needs Review (X PRs)
| PR | Title | Issue | Status |
|----|-------|-------|--------|
| #123 | Fix bug | #456 | No reviews yet |

## Needs Rebase (X PRs)
| PR | Title | Issue | Behind By |
|----|-------|-------|-----------|
| #123 | Update feature | #456 | 5 commits |

## Failing CI (X PRs)
| PR | Title | Issue | Failed Checks |
|----|-------|-------|---------------|
| #123 | Add tests | #456 | e2e-tests, lint |

## Blocked (X PRs)
| PR | Title | Issue | Reason |
|----|-------|-------|--------|
| #123 | Breaking change | #456 | Merge conflicts |

## Healthy PRs (X PRs)
| PR | Title | Issue | Status |
|----|-------|-------|--------|
| #123 | Ready feature | #456 | Approved, CI passing |
```

### 6. Provide Recommendations

For each category, suggest actions:

- **Needs Review:** Tag potential reviewers or request review
- **Needs Rebase:** Provide rebase command or suggest using "Update branch" button
- **Failing CI:** Link to failing check logs, suggest investigation
- **Blocked:** Explain blocking reason and resolution steps

## Usage Examples

**Check current repo:**
```
/pr-checkup
```

**Check specific repo:**
```
/pr-checkup redhat-best-practices-for-k8s/certsuite
```

**Check multiple repos:**
```
/pr-checkup redhat-best-practices-for-k8s/certsuite redhat-best-practices-for-k8s/oct
```

## Notes

- Only checks open issues and open PRs
- Cross-repo PR references are supported
- Draft PRs are included but noted as drafts
- Rate limiting: Uses `gh` CLI which handles GitHub API rate limits
- Results are cached for the current session

## Troubleshooting

- If `gh` CLI is not authenticated, run `gh auth login`
- For private repos, ensure your token has appropriate permissions
- Large repos may take longer to scan; consider using labels to filter issues
