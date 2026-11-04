# Settings model-management owner

The Settings model controls need a different command boundary from first-run
installation. `ModelSetupService::manage` now exposes transcription/translation
re-download, translation-only cancellation and translation presence refresh.
These actions preserve the user's first-run choice and share the existing
pinned downloader, atomic staging, generation checks and shutdown owner.
The isolated Settings window now connects these commands and current native
locations. Translation refreshes on tab selection; snapshots reach both windows.

`locations` returns the same native-selected paths and fast size-based installed
flags used by the original Settings view, plus its decimal disk-GB label. These
presence flags are not SHA-256 integrity evidence. Refresh follows the original
`TranslateModelDownloader.refresh`: an existing size-valid file wins; otherwise
an active download retains its progress, and other states return to idle.

A re-download explicitly starts after joining a prior completed Ready worker.
It cannot silently consume the old success as if a new transfer had completed.
A failed replacement preserves the existing installed bytes. Repeated clicks
while the same transfer is active retain that worker; simultaneous writers do
not compete for its staging file. This is a concurrency guard around the
source behavior, not a claim of byte-identical UI timing.

Translation-only cancellation leaves an in-progress transcription download
running and preserves the first-run recommendation. If the cancel caller goes
away while cleanup is being joined, a repeated cancel still waits for that
owned worker. The cancellation helper is shared with first-run Cancel, so the
same cleanup guarantee applies there. Shutdown remains the final join boundary.

Verification uses actual loopback HTTP transfers with deterministic barriers;
no real model download or user's model is modified. Eight service tests pass,
including three new management tests covering read-only refresh and paths,
installed re-download failure/retry, independent cancellation, duplicate clicks
and dropped callers. Removing the repeated-cancel join fix makes the cleanup
regression fail; restoring it passes. The full local Rust suite passes 96 tests
(12 core / 70 platform / 14 protocol), with formatting and workspace clippy.
See `../evidence/model-management-owner-2026-11-04.json`.

Actual macOS checks verify both installed-status tabs and that Show in Finder
selects `model.q8.safetensors`. Menu open, close/reopen, localization propagation
and Settings folder-panel cancellation also pass. The existing model was not
re-downloaded for UI verification. Transfer/cancel UI, recording-disabled
controls and full visual comparison remain open. See `SETTINGS_CONTRACT.md` and
`../evidence/macos-settings-ui-2026-11-04.json`.
