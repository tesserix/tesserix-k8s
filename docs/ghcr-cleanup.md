# GHCR cleanup

The `GHCR Cleanup (5-day retention)` workflow manages every container package
under `ghcr.io/tesserix`.

For each package it:

1. retains every version updated within the fixed 5-day cutoff;
2. always retains the newest 3 versions, even when they are older; and
3. deletes every other tagged or untagged version.

GHCR deletes package versions rather than individual tag aliases. If several
tags point to one version, those tags are deleted together.

## GitHub App setup

Create a private GitHub App owned by the `tesserix` organization:

1. Disable webhooks; the cleanup does not use them.
2. Grant **Repository permissions → Packages → Read and write**.
3. Install the App on `tesserix` with access to **All repositories**. This is
   required so repository-linked packages are not omitted.
4. Generate a private key.
5. Add the App Client ID as the repository variable
   `GHCR_CLEANUP_APP_CLIENT_ID`.
6. Add the complete PEM private key as the repository secret
   `GHCR_CLEANUP_APP_PRIVATE_KEY`.

The workflow generates a short-lived installation token for every run. The
installation has a separate API rate-limit bucket from user PATs.

GitHub's Packages API currently returns HTTP 400 for organization container
package discovery with installation access tokens in some organizations. The
workflow probes the App token first and automatically uses the existing
`GHCR_CLEANUP_TOKEN` classic PAT only when that specific API defect occurs.
The fallback PAT requires `read:packages`, `delete:packages`, and `read:org`.
The job summary records whether `github-app` or `classic-pat-fallback` was used.

## Retries and continuation

The cleanup follows every GitHub API pagination link, including package-version
pages. It retries network errors, server errors, and secondary rate limits with
bounded exponential backoff. When the primary rate limit is exhausted, it waits
until GitHub's reported reset time.

Installation tokens expire after one hour. The script therefore stops cleanly
at 50 minutes and dispatches a continuation with:

- the same fixed cutoff and dry-run setting; and
- the last completely processed package as a resume cursor.

The workflow concurrency group serializes these runs. If a package was only
partly processed, the continuation repeats that package safely because deletion
is idempotent. Permission and authentication failures fail the job instead of
being reported as successful cleanup.

## First run

Run the workflow manually with `dry-run` enabled and confirm the package and
version counts in the job summary. Then run it manually with `dry-run` disabled.
Scheduled runs execute daily at 03:00 UTC with deletion enabled.
