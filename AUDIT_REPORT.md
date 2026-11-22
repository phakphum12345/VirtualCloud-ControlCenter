# Virtual Cloud Control Center v3.3 — audit summary

## Scope checked

- Control Center GUI and setup flow
- Google Drive OAuth (Desktop + Web clients)
- Google Drive API readiness verification
- GitHub Control Plane bootstrap
- Windows/macOS runner dispatch and runtime state
- Drive Sync, checksum, receipts and retry
- Artifact manager, live monitor, multi-repo, audit and settings
- EXE build package

## v3.3 changes

- Added **Drive API** to System Health.
- Added **Enable Google Drive API** button to Dashboard and Settings.
- Button opens `drive.googleapis.com` API Library; when OAuth JSON is imported, the page is scoped to the OAuth client's `project_id`.
- Added a strict readiness rule: Drive API becomes **Ready** only after a real Drive v3 `about.get` request succeeds.
- Added detection for common API-disabled errors and reports **Disabled** instead of falsely reporting OAuth as Ready.
- Renumbered guided setup: Enable Drive API -> OAuth Client -> Authorize -> Bootstrap.
- `Setup Everything` now opens the required Google Cloud pages when configuration is missing and pauses for the user's explicit Enable/Allow actions.
- After OAuth, Setup Everything verifies Drive API before Bootstrap.
- No `gcloud` dependency was reintroduced.

## Security observations

- The application cannot and should not silently click Google's **Enable** or **Allow** controls on behalf of the account owner.
- OAuth client/token JSON stays out of the package and Git repository.
- Drive credentials remain in user AppData; the current safe Bootstrap does not write GitHub Secrets.
- Health checks reveal status only; they never display secret values.

## Validation performed in the v3.3 release cycle

- Python compile check for `control_center.py` and `bridge_worker.py`.
- YAML parse check for all workflow files.
- GUI smoke test verifies the main window starts and the expected tabs/buttons exist.
- Package ZIP integrity and SHA-256 manifest regenerated.

These are historical release-cycle notes, not evidence that the current repository head has been re-tested. Current CI evidence is recorded in GitHub Actions for the exact commit under test.

## Safety and integrity follow-up

- The current Bootstrap implementation is plan-only by default and performs no remote repository, workflow, commit, push, or GitHub Secret writes.
- Control Center Bootstrap arguments must match the current PowerShell script parameter contract.
- Artifact checksum failures must fail the Drive sync receipt; unsafe manifest paths must never be followed outside the extracted artifact directory.


## Bound Google Cloud project

This build is pinned to Google Cloud project `shift-calendar-engine` for Drive API enablement and OAuth Client creation. OAuth JSON from a different project is rejected to prevent accidental cross-project credentials.

## Repository-wide audit — 2026-11-22

**Canonical repository:** `phakphum12345/VirtualCloud-ControlCenter`  
**Audited base branch:** `feature/virtual-cloud-control-center`  
**Audited commit:** `b469f9f443730d0b753e7b7f78b3895706a80d54`

This section supersedes the historical v3.3 validation notes above for the current repository head.

### Work completed and merged

| PR | Change | Merge commit |
|---|---|---|
| [#5](https://github.com/phakphum12345/VirtualCloud-ControlCenter/pull/5) | Coalesce duplicate background refreshes and report unknown runtime state when the Jobs API fails | `9be1093` |
| [#6](https://github.com/phakphum12345/VirtualCloud-ControlCenter/pull/6) | Validate Actions run IDs and paginate Drive file lookup | `cf0df6c` |
| [#7](https://github.com/phakphum12345/VirtualCloud-ControlCenter/pull/7) | Correct Windows first-run dependency installation and launcher exit codes | `532808f` |
| [#8](https://github.com/phakphum12345/VirtualCloud-ControlCenter/pull/8) | Clarify manual GitHub Secret configuration and local OAuth credential handling | `af232b1` |
| [#9](https://github.com/phakphum12345/VirtualCloud-ControlCenter/pull/9) | Reject duplicate ZIP member names and multiple checksum manifests | `5e44f98` |
| [#10](https://github.com/phakphum12345/VirtualCloud-ControlCenter/pull/10) | Bound downloads, ZIP expansion, manifest size and incremental checksum processing | `625b2da` |
| [#11](https://github.com/phakphum12345/VirtualCloud-ControlCenter/pull/11) | Paginate GitHub Actions jobs and artifacts, validating next-page URLs | `b469f9f` |

### Repository validation evidence

For exact PR head `e521acd77ebde8af177450bd901bf2de417339c4`:

- **53/53 Python unit and contract tests passed** on Windows / Python 3.12.
- Python compile check passed.
- Windows Control Center EXE build passed.
- All **8 YAML files** parsed successfully.
- Bootstrap static audit passed with Windows PowerShell 5.1 and PowerShell 7.
- All repository PowerShell scripts parsed with both Windows PowerShell 5.1 and PowerShell 7.

CI evidence:

- [Repository Quality — PR #11](https://github.com/phakphum12345/VirtualCloud-ControlCenter/actions/runs/45021233535)
- [Bootstrap Safety Audit — PR #11](https://github.com/phakphum12345/VirtualCloud-ControlCenter/actions/runs/45021233540)
- [Post-merge Repository Quality — commit b469f9f](https://github.com/phakphum12345/VirtualCloud-ControlCenter/actions/runs/45021391722)

### Files changed in this work cycle

Modified:

- `control_center.py`
- `bridge_worker.py`
- `run-control-center.bat`
- `README.md`
- `CONTROL_CENTER_README.md`
- `tests/test_bridge_worker.py`
- `tests/test_control_center_contract.py`

No files were deleted and no new source files were required. Existing workflow files were validated; this work cycle did not modify CI workflow definitions.

### Security and operational findings

- Background task coalescing prevents overlapping refresh requests for the same task key.
- GitHub Actions run IDs are validated before API/Drive work; GitHub jobs and artifacts and Google Drive name lookups now follow pagination.
- Artifact verification rejects ambiguous manifests and duplicate ZIP member names. Downloads are capped at **512 MiB per response**, ZIP expansion at **1 GiB**, archive entries at **10,000**, and checksum manifests at **4 MiB**. Oversized or ambiguous inputs fail closed.
- The Windows launcher now returns failure codes rather than exiting after a successful first-run dependency installation.
- The Control Center does not write GitHub Secrets. Required Actions secrets are configured separately by an authorized repository administrator; OAuth authorization remains local.
- Targeted source searches for common private-key and GitHub-token patterns returned no matches. This is not a substitute for a formal GitHub secret-scanning review.
- The safe Bootstrap remains plan-only by default. No live Bootstrap apply, repository provisioning, deployment, production service change, Google Drive data access, or secret operation was performed.

### Remaining risks, limitations and approvals

1. **Branch protection is disabled on the base branch.** GitHub reports `protected: false` and required-status-check enforcement `off`. The PRs in this work cycle were manually merged only after their CI workflows passed, but GitHub does not enforce that policy for future merges. Enabling branch protection and required checks requires repository-owner approval.
2. **Drive folder IDs and the Google Cloud project identifier remain configured in source.** These are identifiers, not OAuth tokens, but they disclose integration metadata. Moving them to per-user configuration requires a backward-compatible migration plan.
3. **Live integration remains unverified.** Real Google OAuth, Google Drive reads/writes, external Control Plane operations and Bootstrap `-Apply` were intentionally not executed under the safety restrictions. CI uses isolated fixtures and static audits.
4. **Interactive GUI startup was not exercised in CI.** The Windows EXE was built successfully; this does not establish a live desktop-session startup or end-to-end OAuth flow.
5. **Artifact size ceilings are intentional compatibility limits.** Artifacts exceeding the documented caps fail closed and would require an explicitly reviewed limit change.
6. The Control Center's configured runtime target repository remains separate from this canonical source repository. It was not used as a development workspace or modified during this audit.

**Audit conclusion:** The merged code changes and CI evidence above are verified for the audited commit. The repository is not certified for live production provisioning or Google Drive operation until the remaining approvals and integration tests are completed.

