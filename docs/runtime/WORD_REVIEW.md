# Low-confidence word review candidate

The Tauri detail transcript now exposes the original low-confidence word links,
word-edit popover, review bar, manual navigation and file-only listen-review
control. Rust owns the queue and playback state. The renderer receives flagged
word references, exact word-spacing decisions and a bounded playback projection.
Source media paths remain private to the native file workflow. Only the main
window can issue review commands.

Queue construction matches the shipping `ReviewController.swift`: confidence is
strictly below the preference threshold, Foundation `.whitespaces` trimming keeps
newlines, empty trimmed words are excluded, and transcript/word order is retained.
Detail rendering uses word position rather than accumulated text length when
inserting spaces; extended grapheme punctuation follows the original Swift
`Character` predicate. Content mode continues using the transcript's normal text.
Threshold changes publish new flagged references even when no new ASR event
arrives. Accepted word edits immediately update the authoritative listening queue;
the visible review bar follows the separately throttled display transcript.

The two original navigation cursors remain distinct. `ContentView.jump` changes
the manual bar index and stops listening, without changing `ReviewController.index`.
Toggling listen mode resumes the controller cursor and synchronizes the bar.
Automatic playback advances without wrapping; manual and popover navigation wrap.
The popover's Apply & next uses the original pre-edit successor rule, including
blank edits. It does not silently replace that rule with a different selection
policy after an asynchronous edit.

macOS reuses the unchanged shipping LinePlayer through the main-thread adapter.
Each word stops the previous span before starting, so consecutive words on the
same line do not trip the line-toggle stop rule. Synchronous stop/start callbacks
are coalesced while restarting. An observed active-line-to-nil boundary advances
only while the review control is visible and listening. Deferred next-span work
checks generation, source, revision and current span before playing. Reset,
replacement, archive opening and quit retire the owner. Hiding the review control
keeps the original listening state but removes boundary observation; it does not
invent an on-disappear stop absent from the original SwiftUI view.

`check_review_parity.py` compiles the unchanged shipping ReviewController with
input scaffolding, and extracts the original flagged-reference, popover navigation
and word-spacing computations. It compares 800 controller cases / 24,000 actions,
400 popover navigation cases and all generated reference/spacing projections.
Windows runs Rust and the frontend navigation against the source-pinned reference.
The oracle excludes SwiftUI observation scheduling, actual audio and visual UI.

```sh
python3 scripts/check_review_parity.py
python3 scripts/check_review_parity.py --rust-only
```

Workflow regressions cover threshold refresh without new transcription, immediate
word-edit queue updates, stale generations and preserved source bytes. Host tests
cover separate manual/listening cursors, same-line restart coalescing, hidden
observers, final-word stop and retired playback. Deliberate threshold, whitespace,
spacing, restart and cursor mutations must be detected before this slice is ready
for review. CI retains both the native and portable differential outputs.

The original AppKit artwork adapter supplies seven review symbols (27 total
symbol configurations). Sizes explicitly set in Swift are copied; controls with
an implicit SwiftUI font currently use 13-point regular artwork and need native
visual comparison. The popover geometry, focus/keyboard behavior, accessibility,
selection and native default animation remain **NOT_RUN**. Review centering
currently reuses the 250 ms frontend easing; the original uses implicit
`withAnimation`, so exact review-animation timing is not claimed.

Actual native playback acceptance remains **FAIL** from the preceding line-player
probe: the unchanged original and a minimal AVPlayer reproduce the current Mac's
CoreAudio output startup timeout (-66681). This slice does not hide or resolve it.
End-to-end listen-review and full UI/UX parity remain **NOT_RUN** while the Mac is
locked. Windows native playback remains unimplemented. See `LINE_PLAYBACK.md` and
`../evidence/macos-word-review-2026-11-05.json` for the recorded scope and checks.
