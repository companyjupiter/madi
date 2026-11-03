# Workspace panel and manual exports

The macOS Tauri file screen now connects the original fixed 267-point right
panel: Files/Stats tabs, recent saved transcripts, auto-save toggle, folder
selection and Markdown/SRT/VTT/plain-text/JSON exports. The source measurements,
assets, colors and static Korean/English/Japanese strings are retained. The
original `showExplorer`/`explorerWidth` storage declarations do not control the
current Swift body; the port follows that body rather than reviving unused UI.

This is a connected candidate, **not a UI/UX parity acceptance**. Actual WKWebView
geometry, text, animation, accessibility/focus, file dialogs and the SwiftUI
export-format confirmation dialog require native comparison. The web format
popover and loading spinner are provisional presentations. The native Mac is
locked at the last refused UI operation; no capture workaround has been used.
Recording/live summary, AI tools, settings UI, playback, start-screen recent
items, Windows workspace adapters and full product behavior remain open.

## Ownership and settings

`Workspace` serializes settings and publishes revisioned snapshots. Read-only
scans/statistics run off the UI thread; generation and request tokens reject late
results after folder changes or tab changes. Row IDs resolve only against the
currently published native list. The renderer cannot supply an arbitrary open,
export or workspace path. Confirmed folder/export panels execute on the main
thread; accepted changes remain owned if the JavaScript caller disappears.

The original `com.companyjupiter.madi` preference domain supplies a **read-only**
fallback for exactly three non-secret keys: `autoSaveEnabled`, `autoSaveFolder`
and `editorSettings`. Later changes use `workspace.json` under Tauri's isolated
app configuration directory. Existing valid Tauri preferences win on relaunch.
An invalid existing file is retained and reported, never silently replaced.
No real-user preference migration was exercised by the temporary-folder tests.

On a first launch without a stored folder, the native Documents/madi fallback is
prepared like Swift. The connected host now enables archive persistence using
these settings: a file transcription can create a new Markdown archive in the
selected folder. Changing the folder applies to the next session; an existing
session keeps its already-owned checkpoint. Opening a saved meeting is read-only
and does not acquire it as a checkpoint. Edits alone do not trigger autosave.

Settings publication queues archive changes in the same order. Frontend workspace
commands are also serialized, and snapshot revisions prevent late responses from
replacing newer data. Shutdown joins file writes before stopping workspace and
model owners. Superseded read-only scans may finish after shutdown but cannot
write or publish into the closed owner.

## Native enumeration and statistics

The scanner uses the same Foundation directory enumeration, hidden-file rules,
localized natural ordering and URL semantics as Swift: directories first, four
levels and at most 2,000 entries per directory **before sorting**. The flat list
includes all Markdown transcripts, including summary siblings, newest mtime first.
Statistics exclude summary siblings and unparseable text. They reread the file's
modification date, so a checkpoint update is reflected without rescanning the tree.
Nonfinite imported timecodes are rejected before display formatting.

`NSCalendar` supplies local week boundaries, including DST/year transitions.
`NSNumberFormatter` supplies the system-locale word count. The aggregate and its
average values match `WorkspaceAnalytics`; a same-path checkpoint refreshes an
open statistics tab without inventing a recent-list reload.

## Export behavior

Markdown/plain text reuse the already-verified archive core. Caption export ports
`CaptionSpec` and `captionCues`: edited-text timing synthesis, speaker labels,
wrapping, duration/CPS limits, overlap trimming and millisecond formatting.
JSON includes segments/words/current translations, speaker durations, filler and
silence cuts, tighten summary, chapters, retakes and highlights. `EditorSettings`
uses Swift's missing/null upgrade defaults; its master switch does not suppress
fields that Swift exports independently.

macOS JSON bridges numbers directly to `NSNumber` and uses Foundation's pretty,
sorted, unescaped-slash writer. A decimal stringify/parse intermediate was rejected
because it changed Double rounding. Equal-duration speaker order remains a known
Swift Dictionary nondeterminism; comparisons canonicalize only those ties.
Windows portable comparison checks the same data and exact caption bytes, not
macOS JSON whitespace/number formatting.

The save panel uses the original `transcript.<extension>` name. Its selected path
and overwrite confirmation remain native-owned. The file owner reads the current
**authoritative store after confirmation**, rather than a coalesced display copy.
A reset invalidates the generation and writes nothing. Serialization and atomic
same-directory replacement run as one owned operation that shutdown joins. A
failed export preserves the previous destination and cleans its temporary file.
Native overwrite dialogs themselves have not been exercised in this stage.

## Verification

- `check_workspace_parity.py`: live unchanged Swift scan/recent logic and
  aggregation, 2,017 nodes in three temporary fixtures and 57 calendar cases.
- `check_export_parity.py`: live unchanged Exporters/EditorCuts, 610 cases,
  1,566 fixture words and 3,502 cues; exact JSON bytes in 373 deterministic-order
  cases. Windows uses `--rust-only` against pinned source/corpus/result hashes.
- Rust tests: stale scans/stats/rows/pickers, preference retention, statistics
  summary exclusion and fresh mtime, checkpoint ownership after folder/toggle
  changes, all five manual formats, latest edits, stale exports, failed writes
  and canceled callers followed by joined shutdown.
- Native owned-symbol check covers eight SF Symbols, including folder/export.
  This checks dimensions and nonempty transparent bitmaps, not UI pixels.
- The headless native workflow probe extends the bundled decoder/Metal inference
  test with temporary workspace scan/statistics, preference persistence and five
  exports. It does not exercise renderer IPC or dialogs.

Tauri integration follows the official [command API](https://v2.tauri.app/develop/calling-rust/)
and [window-scoped capabilities](https://v2.tauri.app/security/capabilities/).
Only the five explicit workspace commands are added; no generic filesystem,
shell, remote-origin or arbitrary-path capability is granted.
