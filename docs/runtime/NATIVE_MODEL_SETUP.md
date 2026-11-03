# Native model setup

The experimental macOS Tauri host now connects `ModelGateView.swift`'s first-run
guide to a Rust model service. This is implementation and headless behavior
evidence, not a completed UI/UX parity gate or product release.

## Entry and presentation

`ModelSetupService` reads the existing Madi model paths and original size-only
launch policy without creating directories or a network client. Whisper ready
with no explicit setup choice enters immediately. Choosing recommended setup
waits for DNA only when its matching engine exists; transcription-first
continuation leaves an active DNA download running. Variant choice follows the
original memory/override rule. The existing 48-case policy oracle remains fixed.

The WebView subscribes before reading a snapshot and rejects older revisions.
Rust owns the policy and accepts only start/retry/cancel/continue intents; paths,
URLs, checksums and target sizes never come from the WebView. macOS artwork is
generated lazily on the main thread from the original five SF Symbol names,
sizes and weights. It is not included in Windows assets. Foundation supplies the
original byte-count formatting. All 26 model-guide string triples are extracted
from the unchanged Swift source, including native-formatted dynamic values.

Windows remains an explicit setup harness without native model-guide integration.
The UI language is still selected by the harness URL, not migrated preferences.
The original beta gate and Settings model lifecycle are not connected yet.

## Transfer and ownership

Only explicit setup actions create an HTTPS-only reqwest client using native OS
TLS. Files go to an app-owned `.madi-downloads` directory under Madi Application
Support. Each asset has an OS lock, kept at a stable path, and a private partial
file. A new attempt can truncate its own interrupted partial only after taking
that lock. No range-resume claim is made. Links/nonregular staging and destination
files are rejected. Download size and full pinned SHA-256 must pass before an
atomic same-directory-tree rename publishes the model.

Transfer/verification failure preserves a previously installed file. This is a
deliberate data-preservation improvement over the original Whisper error path,
not proof of identical internal file operations. Native network error wording
can differ between reqwest and Foundation and still needs a parity decision.

Progress is coalesced, terminal events bypass throttling, and generation IDs
prevent an old attempt updating its replacement. Cancel signals both active
downloads before awaiting cleanup; retry waits for old handles/locks to close.
As in the original view, Cancel is exposed for downloading states, not verification.
Application exit requests cancel/join owned work before the Tauri runtime exits.
Hard interruption recovery is tested for stale partial files; power-loss durability
and live multi-process interaction with the shipping Swift downloader remain open.

## Evidence and remaining work

- Eight real loopback HTTP/temporary-filesystem tests cover verified install,
  same-size corruption, truncation, oversize input, preserved existing files,
  cancel/retry, lock exclusion, dropped waits/owners, stale partials, links,
  read-only initialization, duplicate start, late completion, transcription-first
  continuation, absent DNA engine and shutdown cleanup.
- `check_model_gate_parity.py`: 210 state/action-visibility cases against extracted
  unchanged Swift view rules; Windows compares the pinned result, without Swift.
- `check_model_presentation_parity.py`: nine live Foundation byte-count cases,
  physical memory and five native symbol dimensions; generated PNGs have visible
  and transparent pixels. This is not a screenshot or pixel-parity comparison.
- The frontend builds and the native command manifest has explicit permissions.
  CI regenerates copied resources/localized strings and rejects drift.

The latest local complete Rust suite passes 57 tests (11 core, 14 protocol,
32 platform). An initial fixture failure inherited nonblocking mode on an accepted
socket; the server now explicitly switches it off. A separate unbounded test-server
accept was terminated after an absent request; bounded accept now exposes such a
failure instead of hanging. The isolated retry and subsequent full suite passed.
The latter absence's underlying trigger was not reproduced; CI must confirm the
new revision. The failed/hung attempts are not counted as successful runs.

Native click flows, actual production download through the Tauri view, exact
SwiftUI/WebView fonts/buttons/spacing, accessibility/keyboard behavior, all
languages/themes and close-during-download UI behavior still require an unlocked
Mac. Existing multi-GB user models were not replaced or downloaded for these
tests. No visual parity exception is approved by this implementation.
