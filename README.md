# DRIVE_VIRTUAL_CLOUD Control Plane v3.3

This package connects a Google Drive-backed Virtual Cloud to GitHub-hosted Windows/macOS runners.

## Flow

`Control Center -> Enable Drive API -> OAuth browser authorization -> GitHub Actions -> Windows/macOS runner -> artifact/log/metadata/checksum -> Drive Sync -> receipt`

## Google Cloud setup

The Control Center includes buttons for the full Google setup sequence:

- **Enable Google Drive API** opens the API Library page for `drive.googleapis.com`; when an OAuth JSON is already imported, the page is scoped to that JSON's `project_id`.
- **Create / Manage OAuth Client** opens Google Auth Platform / credentials.
- **Authorize Google Drive** opens the browser consent flow and creates refreshable user credentials.

The `Drive API` health status is verified with a real Drive v3 request after OAuth. Opening the Cloud Console alone does not mark it Ready.

Desktop OAuth client is recommended. Web OAuth client is also supported when it includes a localhost redirect URI, recommended:

`http://localhost:8765/oauth2callback`

## Workflows

- `.github/workflows/virtual-cloud-runners.yml` — manual Windows/macOS runner dispatch.
- `.github/workflows/virtual-cloud-drive-sync.yml` — automatic post-run sync plus manual retry.
- `.github/workflows/build-control-center.yml` — builds `VirtualCloudControlCenter.exe` on `windows-latest`.

Runner dispatch fails if no project build hook is present. A runner-only smoke test is available only through the explicit `allow_noop=true` workflow input and is clearly labelled as a no-op.

## Bootstrap safety contract

`bootstrap-control-plane.ps1` is deliberately plan-only by default. It verifies the configured target repository and prepares a local review plan; it does not create repositories, write GitHub Secrets, stage files, commit, push, or publish workflows. The Control Center's **Prepare Safe Bootstrap Plan** action uses only the script's supported `-Repo` argument. Any future remote provisioning or secret-writing operation must be a separate, explicitly approved workflow.

The workflow YAML files and application files in this source repository are package templates. Bootstrap maps them into the target Control Plane layout under `.github/workflows/`, `tools/virtual-cloud/`, and `app/`.

## Bridge

`bridge_worker.py` is idempotent. It updates same-name files, verifies SHA-256 manifests and writes Drive sync receipts plus pending/completed/failed status records. A failed or unsafe checksum manifest causes the sync to be marked failed rather than reporting a successful receipt.

## Required GitHub Secrets

- `GDRIVE_USER_CREDENTIALS_JSON`
- `GDRIVE_ARTIFACTS_FOLDER_ID`
- `GDRIVE_LOGS_FOLDER_ID`
- `GDRIVE_RUN_METADATA_FOLDER_ID`
- `GDRIVE_CHECKSUMS_FOLDER_ID`
- `GDRIVE_RECEIPTS_FOLDER_ID`
- `GDRIVE_SYNC_PENDING_FOLDER_ID`
- `GDRIVE_SYNC_COMPLETED_FOLDER_ID`
- `GDRIVE_SYNC_FAILED_FOLDER_ID`

Optional for private cross-repository checkout:

- `MULTI_REPO_TOKEN`


## Bound Google Cloud project

This build is pinned to Google Cloud project `shift-calendar-engine` for Drive API enablement and OAuth Client creation. OAuth JSON from a different project is rejected to prevent accidental cross-project credentials.
