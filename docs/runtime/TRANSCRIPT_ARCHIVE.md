# Transcript archives and session persistence

The Rust core now exports the shipping Markdown/plain-text formats and reopens
Markdown using the original `TranscriptArchive.swift` rules. The platform writer
owns the checkpoint filename, and `FileWorkflow::with_archive` connects it to the
30-second timer and successful/failed file-session completion.

The macOS Tauri host now constructs the persistence-enabled workflow from its
isolated workspace preferences. The native panel, save toggle, folder selection,
archive opening and five manual export formats are connected. See
[Workspace and exports](WORKSPACE_AND_EXPORTS.md) for the ownership boundary and
remaining native UI acceptance. Tests use temporary folders; real-user settings
and native save/reopen interaction have not been exercised.

## Preserved behavior

- Low-confidence words below 0.55 use Markdown italics. Edited text overrides raw
  words; current translations export in language order; stale translations do
  not export. Summary, overlap, speaker labels and timecode formatting follow the
  unchanged Swift methods.
- Reopening is intentionally lossy: each word inherits its line's start time,
  italic words receive confidence 0.3, ordinary words receive 1.0, overlap markers
  are discarded and imported translations are user-owned. New UUID values are
  generated; each nonempty line uses its first word's identity.
- Explicit `Speaker N` IDs are reserved before allocating named speakers. Unknown
  remains ID 255. Canonically equivalent names and translation keys behave like
  Swift strings. Spaces and asterisks use grapheme boundaries, so a combining
  asterisk/keycap is not silently stripped as Markdown markup.
- A session updates one checkpoint path even if later calls supply another base
  or folder. Reset releases that pointer; a new session allocates `name 2.md`,
  `name 3.md`, and so on. Summary files use `name 요약.md`; rename moves the first
  matching companion and updates the transcript pointer before a companion error.
- Reopening first parses the file, then retires the previous session. Unreadable,
  unrecognized, busy or stale-generation requests preserve the current meeting.
  Opening an archive never claims it as the new writable checkpoint target.
- Inline edits alone do not add an autosave trigger absent from Swift. An active
  engine failure saves the partial transcript; a model-admission error has no
  active session and does not finalize/rebuild an imported archive.

## File ownership

Writes use a hidden temporary file in the destination directory, flush its data,
then persist it. Fresh names use atomic no-clobber allocation and retry collisions,
including concurrent sessions. Existing session checkpoints replace only their
owned destination. A failed write does not advance the pointer; errors remain
separate from the transcription result. New filenames cannot escape the selected
folder through path separators. Nonfinite imported timestamps and integer
overflow that would trap the original UI/parser are rejected.

macOS filename construction uses Foundation URL APIs, including filesystem
decomposition that differs from ordinary Unicode NFD. Same-volume rename uses
`renamex_np(RENAME_EXCL)`; Windows uses `MoveFileExW` without replace-existing.
Cross-volume copy/remove support has not been exercised. Full power-loss durability,
network filesystems, hostile external replacement of owned files, error-message
localization and native UI behavior are not certified by these checks.

The serialized workflow owns every blocking disk operation until it returns.
Reset, another session and shutdown cannot detach a write that later mutates a
new session. Actual disk work runs outside the UI thread. Slow/network storage
latency and long-session performance still require measurement.

## Evidence

```sh
python3 scripts/check_archive_parity.py
python3 scripts/check_archive_writer_parity.py
cargo test --locked -p madi-platform
```

On Windows the two differential scripts use `--rust-only` against pinned Swift
source/corpus/result hashes. Live macOS compares 284 format/reopen cases including
1,566 fixture words, and 48 real-file writer sequences with 825 intermediate
states. Format comparisons use exact UTF-8 and floating-point bits, with UUID
identity invariants rather than equal randomly generated UUID values.

Writer comparisons check canonical filenames, full file bytes, pointer changes
and error presence. The portable reference additionally canonicalizes only the
filename-derived summary heading; summary/transcript body bytes stay exact.
Error wording is not compared. Separate Rust tests exercise 12 simultaneous
writers, existing-file preservation and checkpoint failures. Real child-process
tests wait for the production 30-second checkpoint, then exercise completion,
failure, disabled persistence, reopen, admission failure and a fresh colliding
session. The native smoke probe uses the bundled decoder/ASR and a public JFK
recording with a temporary archive folder.

SRT/VTT/JSON export and workspace scanning/selection are connected in the next
candidate described in `WORKSPACE_AND_EXPORTS.md`. Summary generation, complete
product preference migration, actual native save/reopen interactions and full
UI/UX equivalence remain open. The archive foundation evidence is retained in
`docs/evidence/macos-transcript-archive-2026-11-04.json`.
