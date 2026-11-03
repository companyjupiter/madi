# Transcript assembly and edit model

`madi-core::transcript` ports the shipping Swift `WordMerger`, `Line`,
`TranscriptStore` and `SpeakerDisplayNumber` synchronous model. It preserves
word/line UUIDs, held-word replacement, seam/instant deduplication, phrase-repeat
limits, live/final grouping, frozen prefixes, settled boundary decisions,
speaker corrections/overlap, display numbers and user edits. Original line
limits remain 28 words / 14 seconds, with the 16-word clause boundary.

Translations remain revision-bound overlays. Cosmetic edits rebind their
provenance; material edits retain older text as stale display content. User
translation edits resist guard suppression. Removing a translation target,
reopening already parsed lines, resetting a session and finalizing retain the
original policies. This does not implement translation inference, queues,
archive parsing/writing or autosave. The separate file-workflow candidate now
connects this model to the desktop transcript view.

The store is synchronous and has no runtime or OS dependencies. It marks render
and speaker-fix work pending; `madi-platform::file_workflow` now delivers the original
33 ms / 50 ms callbacks and publishes snapshots. Reset, archive load and finalize
publish immediately without cancelling an already scheduled render, as Swift
does. Explicit model delivery and real workflow timer publication are tested.
Energy/speaker-share/flagged-word display caches are not ported by this change.

Text bytes are preserved. Comparison keys use Foundation whitespace rules,
extended grapheme clusters, scalar lowercase and canonical equivalence. Using
Rust's context-sensitive string lowercase incorrectly deduplicated the Greek
`ΟΣ`/`ος` seam; the Swift comparison exposed that difference. NFC applies to
comparison only, never stored words, edited text or the stable FNV revision.

## Comparison gates

Run with the pinned toolchain on PATH:

```sh
python3 scripts/check_word_merger_parity.py
python3 scripts/check_transcript_store_parity.py
```

The word gate compares 301 cases / 1,974 intermediate snapshots. The store gate
compares 309 cases / 5,947 snapshots. Each includes 1,566 real word payloads from
the three checked-in JSONL fixtures. Those files do not contain the stdout
word-section/speaker-window stream; JSONL segment metadata is not fabricated
into missing stdout events. Dedicated synthetic cases exercise those events.
The store corpus includes the original frozen-join and weak-island regressions,
all 32 grouping-feature combinations, deterministic mixed-event sequences,
line caps, stale revision guards, edits, overlap, reset and reload.

Swift production method bodies are compiled unchanged. Only logging and
translation telemetry are stubbed. A same-file extension injects deterministic
word IDs and explicitly delivers the original render callback; a synchronous
MainActor entry point prevents background timer races. Returned values, every
line/word ID, exact UTF-8 text, double bit patterns, revision hashes, translation
states, display snapshots and counters are compared. The comparison does not
permit tolerances on these values. These tests cover finite engine inputs.

Both gates pin source/fixture/corpus/result hashes in `design/parity`. Windows
runs `--rust-only` against those live-Swift-generated references; that is not a
live Swift run on Windows. CI retains reports and normalizes source fixture
line endings. Regenerating a reference requires a successful live comparison.

## Native execution evidence

The `file_session_smoke` example now ingests actual stdout into `TranscriptStore`
and finalizes after the file executor's terminal callback. Through a copied app
outside the repository, the existing native decoder and Metal ASR produced 22
words and the expected JFK sentence, one completion and no failures. The source
WAV hash and existing model size/mtime were unchanged; owned scratch was empty
at completion and shutdown. Speaker-fix work is explicitly flushed at finish
in this probe. It does not exercise a live display timer or a Tauri screen.

```sh
cargo run --locked -p madi-platform --example file_session_smoke -- \
  '<copied-app>/Contents/MacOS/transcribe' '<existing-whisper-model>' \
  '<copied-app>/Contents/Resources/assets-small' '<public-jfk.wav>' \
  '<scratch-parent>' '<copied-app>/Contents/MacOS/madi-audio-decode'
```

See [`macos-transcript-model-2026-11-04.json`](../evidence/macos-transcript-model-2026-11-04.json).
Native pixel/interaction parity, settings/glossary policy,
translation and persistence remain required before the file-start product flow
can be considered migrated.

## Connected file owner

`FileWorkflow` serializes start, reset and identity-scoped edits around
`FileSession`. A generation prevents an old screen's reset/edit from changing a
replacement session. Duplicate starts while processing are ignored. A cancelled
request does not cancel the owner; shutdown retains its task until child cleanup
finishes. A transport fault retires and replaces the executor before retry.
Terminal snapshots include finalized text and arrive after owned WAV cleanup.
Native decode failures retain the original `AudioDecode.reason` product message.

Six real-child fixture tests cover streaming publication, delayed speaker fixes,
stable identity through edits, revision-bound translations, Foundation name
trimming, duplicate starts, reset/cancellation, stale generations, decode/engine
errors, transport-fault retry, dropped owners and interrupted shutdown waits.
These are process fixtures, not inference-quality or UI claims.

The Tauri setup file button now consumes its native selection and starts this
owner. The working view receives progress and transcript snapshots; back/close
reset it, detail edits target line identities, and copy/name actions dispatch to
AppKit. Working-screen native file selections start immediately when allowed;
processing rejects replacements. The content/detail candidate includes bounded
paragraphs, conditional speaker-island folding and source text from the original
catalog. Native alert geometry, clipboard clicks, scroll/focus behavior, resizing,
typography and pixels remain unverified. No capture, settings migration, archive
autosave, workspace, playback, glossary, AI postprocessing, translation generation,
derived statistics or low-confidence review has been completed. The follow
state model and DOM adapter are now connected separately; see
[`TRANSCRIPT_FOLLOW.md`](TRANSCRIPT_FOLLOW.md) for exact model comparisons and
the still-open native interaction/visual gates.

The archive foundation now connects optional persistence and reopen to this
owner; see [`TRANSCRIPT_ARCHIVE.md`](TRANSCRIPT_ARCHIVE.md). Its temporary-folder
checks do not imply that the Tauri workspace/settings boundary is connected.

`file_workflow_smoke` runs the timed owner using explicitly supplied native engine,
decoder, assets and a public source fixture. It verifies the completed transcript,
edit identity, reset, rejection of a stale edit, source hash preservation, model
size/mtime preservation and empty scratch. It does not create a native window or
exercise web IPC, AppKit dialogs or the clipboard.
