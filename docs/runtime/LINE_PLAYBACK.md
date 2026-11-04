# Native line playback candidate

The file transcript's detail-row header now exposes the original play/pause
control when the current session has source media. Continuation rows and content
mode retain their original layout. The icons use AppKit's `play.circle` and
`pause.circle.fill`, 12-point regular weight; active color and Korean/English
help follow `TranscriptView.swift`. Japanese retains the original English help.

The native file workflow retains the admitted source path privately. A snapshot
exposes only `hasSourceMedia`; the playback command accepts a displayed UUID,
start/end time and session generation, never a path. The command resolves the
source in the workflow and rechecks the current generation on the main thread
before using it. Reset, archive opening and new sessions retire the old player.
An admission failure preserves the previous source, as in SessionController.
Ordinary transcript updates do not interrupt playback. Reconciliation reads
only the generation/source-presence pair, without cloning transcript history
on every meter update. Quit retires playback before asynchronous persistence
and engine cleanup; late callbacks cannot reopen the closed owner. Settings and caption
windows have no playback capability.

macOS compiles the unchanged shipping `Audio/LinePlayer.swift` into the native
adapter. It preserves exact seek tolerance, nonnegative start, minimum 0.3-second
end boundary, same-line stop and player-identity checking for late seek callbacks.
The Rust owner is neither Send nor Sync. Its stable callback allocation outlives
the Swift endpoint, and destruction stops playback before releasing that callback.
The Tauri main thread owns the player; generation checks reject old callbacks.
React serializes rapid toggles and receives the native current-line projection.
There is no continuous audio retained for live-session playback. Windows native
playback remains unimplemented. The subsequent word-review candidate connects
the review controller to this adapter; see `WORD_REVIEW.md`.

The source-owner regression checks completion, admission failure, stale requests,
archive opening, reset, unchanged original bytes and scratch cleanup. A host test
checks late callbacks across replacement/reset. The original artwork oracle now
includes the two playback states (20 total symbol cases).

`line_playback_probe` exercises the actual adapter against a caller-owned silent
four-second WAV: three boundary spans, tap-again, rapid A/B/A, stop/drop during
pending seeks and nonfinite-input rejection. It reports boundary failures and
continues teardown checks, then exits nonzero if any boundary fails. It requires
a debug macOS build and does not certify audible output or screen interaction.

```sh
cargo run --locked -p madi-platform --example line_playback_probe -- /path/to/silent-four-seconds.wav
```

On the current locked Mac (2026-11-05), all four automatic boundary checks
**FAIL**: the playback clock does not advance. Tap-again, explicit stop, pending
drop and nonfinite-input checks pass. An independently compiled unchanged
LinePlayer and a minimal AVPlayer without seek or boundary observers reproduce
the zero-time pause. Both 16 kHz WAV and 48 kHz AIFF reproduce it. The minimal
player's system log records a 15-second CoreAudio output startup timeout followed
by `kAudioQueueErr_CannotStart` (-66681) and `PlaybackFailed` on the built-in speaker
route. The SDK header confirms the error constant. The screen is locked, but
the causal relationship between locking and the audio failure is unproven.

Native playback acceptance remains **FAIL**, and native UI/UX comparison remains
**NOT_RUN**. No retry, forced playback policy or audio-service restart hides this
result. Recheck the device/output environment, repeat the actual probe, then
compare source and candidate UI interactions when the Mac is unlocked. App builds
and lifecycle tests do not close that gate. See the source-pinned receipt in
`../evidence/macos-line-playback-2026-11-05.json`.
