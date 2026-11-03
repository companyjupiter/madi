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
archive parsing/writing, autosave or the transcript UI.

The store is synchronous and has no runtime or OS dependencies. It marks render
and speaker-fix work pending; the future session host must deliver the original
33 ms / 50 ms callbacks and publish snapshots. Reset, archive load and finalize
publish immediately without cancelling an already scheduled render, as Swift
does. Explicit delivery is verified; actual timer scheduling is still open.
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
Native pixel/interaction parity, session-host delivery, settings/glossary policy,
translation and persistence remain required before the file-start product flow
can be considered migrated.
