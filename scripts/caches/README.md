# Shared Cache Files

This directory contains centralized cache files that are shared across all lookup scripts in this repository. These caches help reduce redundant GitHub API calls and speed up scans.

## Cache Files

### `forks.txt`
Lists repositories that are forks of upstream projects. Fork repositories are typically skipped during scans since they should stay in sync with their upstream.

### `abandoned.txt`
Lists repositories that have not been updated in over 6 months (no commits to the default branch). These inactive repositories are skipped to focus on actively maintained projects.

### `no-gomod.txt`
Lists repositories that do not contain a `go.mod` file at the repository root. These are either non-Go projects or pre-modules Go projects.

## Format

Each cache file is a plain text file with one repository per line in `owner/repo` format:

```
openshift/example-repo
redhat-best-practices-for-k8s/another-repo
```

## Updating Caches

Caches are updated daily by the `update-caches.sh` script, which:

1. Scans all configured GitHub organizations
2. Identifies fork, abandoned, and no-go.mod repositories
3. Updates the cache files if there are changes
4. Creates a pull request if any caches have changed

To manually refresh caches:

```bash
./scripts/update-caches.sh
```

## Scripts Using These Caches

- `go-version-checker.sh`
- `xcrypto-lookup.sh`
- `gomock-lookup.sh`
- `ioutil-deprecation-checker.sh`
- `ubi-lookup.sh`
- `golangci-lint-checker.sh`

## Notes

- All cache files are checked into git to ensure consistent behavior across runs
- The scripts will create these files if they don't exist on first run
- Manually editing these files is supported but should be rare
