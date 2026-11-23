# Virtual Cloud Control Center v3.3

Windows desktop control application for `DRIVE_VIRTUAL_CLOUD` + GitHub Actions.

## Google Cloud + Drive setup is now guided in the app

The Dashboard Setup row now contains the complete sequence:

1. **Enable Google Drive API**
2. **Create / Manage OAuth Client**
3. **Authorize Google Drive**
4. **Bootstrap / Update Control Plane**

`0. Setup Everything` walks through those stages and stops only when Google requires an explicit browser action from the account owner.

### Enable Google Drive API

The **Enable Google Drive API** button opens the official Google Cloud API Library page for `drive.googleapis.com`.

- If an OAuth client JSON has already been imported, Control Center reads its `project_id` and opens the Drive API page scoped to that exact Cloud project.
- If no client has been imported yet, Google Cloud opens with project selection. Choose the same project that will own the OAuth client.
- Click **Enable** in Google Cloud if the API is not already enabled.

Control Center does not claim that the API is enabled merely because the page was opened. After OAuth exists, the `Drive API` System Health item is verified by making a real Drive v3 `about.get` request. It becomes **Ready** only when that request succeeds.

## Google authorization — browser flow

On first use:

1. Click **Create / Manage OAuth Client** and create either a Desktop application client (recommended) or Web application client.
2. Download the OAuth client JSON.
3. Click **Authorize Google Drive** and select that JSON once.
4. The app imports the client configuration to the private app-data folder.
5. Your browser opens the Google consent page.
6. Approve the Drive permission.
7. The app receives the callback and stores refreshable user credentials in the private app-data folder.
8. Click Refresh. `Drive API` and `Drive OAuth` should both become **Ready**.

### Supported OAuth client types

**Desktop application client**

- Recommended for this Windows desktop Control Center.
- Uses Google's installed-app local server flow.

**Web application client**

- Supported through an authorization-code callback.
- Must contain an Authorized redirect URI on localhost.
- Recommended: `http://localhost:8765/oauth2callback`
- OAuth state is validated before token exchange.
- Offline access is requested so Drive Sync can refresh the token without asking for approval on every run.

## Security

- OAuth client JSON is stored at `%APPDATA%\DriveVirtualCloudControlCenter\google-oauth-client.json` by default.
- Generated Drive user credentials are stored at `%APPDATA%\DriveVirtualCloudControlCenter\gdrive-user-credentials.json` by default.
- OAuth/token JSON is not included in the package ZIP.
- OAuth/token files are excluded by `.gitignore` and are never committed by Bootstrap.
- Web OAuth callbacks accept only explicit-port HTTP loopback URIs (`localhost` or `127.0.0.1`); callback error text is HTML-escaped.
- The safe Bootstrap script does not write GitHub Secrets or send OAuth credentials to GitHub.
- The optional **Configure Private Multi-Repo Access** action asks for explicit confirmation, reads the active `gh auth token`, and writes it only as `MULTI_REPO_TOKEN` to the configured control repository. It does not display the token or save it in local settings; it is separate from Bootstrap and does not write the Drive secrets.
- Any future transfer of Drive credentials or folder IDs to GitHub Secrets must be separately approved and performed through a dedicated secure operation.
- Secret values are never displayed in the Control Center.
- Local settings, OAuth client JSON, and generated OAuth credentials are written through atomic file replacement to avoid partially written files.
- Drive cleanup reports partial or failed deletions explicitly; failed deletions are never counted as successful.

## Existing capabilities

- Real Windows/macOS job status from GitHub Actions.
- Run Windows, macOS, or both.
- Cancel / Re-run / Re-run Failed.
- Retry Drive Sync without rebuilding.
- Live job/step monitor.
- Background refresh requests are coalesced per task to avoid overlapping GitHub/Drive calls; GitHub API failures display **Unknown** rather than a false **Idle** state.
- Manually entered GitHub Actions run IDs are validated before use in API paths or sync retry commands.
- Run details: branch, SHA, actor, timestamps and duration.
- Artifact Manager with download and SHA-256 verification.
- Drive sync receipts and Sync History.
- Multi-repo browser and workflow selector.
- Optional private cross-repo access via `MULTI_REPO_TOKEN`.
- Audit log, auto refresh, notifications, settings backup/restore, retention cleanup, and EXE build.

## Bridge artifact resource limits

The Drive Sync bridge fails closed when downloaded content exceeds its resource limits:

- Each GitHub artifact or job-log response is limited to **512 MiB**.
- Each artifact ZIP is limited to **1 GiB total uncompressed content** and **10,000 ZIP members**.
- The `SHA256SUMS.txt` manifest is limited to **4 MiB**.
- ZIP members are hashed incrementally; duplicate member names and ambiguous checksum manifests are rejected.
- Oversized or invalid artifacts do not produce a successful sync receipt.

## First setup

1. Ensure GitHub CLI (`gh`), Git and Python are installed.
2. Start `run-control-center.bat` or `VirtualCloudControlCenter.exe`.
3. Click `0. Setup Everything`.
4. Sign into GitHub if prompted.
5. Enable Google Drive API in one Cloud project.
6. Create/download the OAuth client JSON from that same project.
7. Authorize Drive in the browser.
8. When `Drive API` and `Drive OAuth` are Ready, use **Prepare Safe Bootstrap Plan** to verify the configured target repository and review the local plan. This safe Bootstrap script does not create/update a remote repository, publish workflows, commit, push, or write GitHub Secrets.
9. Provisioning a repository or configuring Drive folder Secrets is a separate privileged operation and is not performed by the safe Bootstrap action.
10. Dispatch a Windows/macOS job and verify Artifact -> checksum -> Drive Sync -> receipt.


## Bound Google Cloud project

This build is pinned to Google Cloud project `shift-calendar-engine` for Drive API enablement and OAuth Client creation. OAuth JSON from a different project is rejected to prevent accidental cross-project credentials.
