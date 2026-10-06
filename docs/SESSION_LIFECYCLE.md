# Session lifecycle and persistence boundaries

The next-version refactor keeps `SessionController` as the UI-facing composition
root. Its transcript, translation and summary policies stay in place; lifecycle
and filesystem operations now have independently executable contracts.

## Ownership

| Component | Owns | Does not decide |
|---|---|---|
| `SessionCoordinator` | Phase, recording clock, countdown, capture/start task, file preparation task, current engine, startup/flush deadlines, normalized import WAV | Translation routing, text corrections, summaries, archive format |
| `SessionEngineAdapter` | Mapping the existing `EngineProcessDelegate` protocol to session outputs | State transitions or retry policy |
| `AudioCapture` | One input instance and its unique segment directory | Session completion or engine lifetime |
| `SessionArchiveWriter` | Saved transcript URL, atomic checkpoints, collision-safe names, companion summary writes, renames, last write error | When a session is complete or whether auto-save is enabled |
| `SessionOneShotTranscriber` | One correction process, cancellation-safe launch, 45-second deadline, plain-file output parsing | Which line needs correction or whether its source revision still matches |
| `SessionController` | UI policy, model configuration, transcript/AI work, stalled-segment detection/refeed, permission messages, autosave cadence | Direct transcription process ownership or writable phase |

Both `Package.swift` and `scripts/make_app.sh` include the new Session files.
`EngineProcess` and its path policy are also in the headless test target, so tests
exercise real Process pipes through the adapter. No model or microphone is needed.

## Contracts

1. A new recording, file import or reset uses one product-data reset path. Old AI
   clients detach before their state is cleared. Session generations reject late
   translation, summary, file preparation and one-shot correction results.
   Reset/failure also cancels the tracked correction task and its running process;
   a stuck correction has a 45-second termination deadline.
2. Engine replacement changes the engine identity without restarting capture.
   Old process events are ignored even if queued before delegate detachment.
3. Live startup has one 45-second deadline covering engine readiness **and**
   asynchronous capture startup. A late capture completion aborts its original
   instance; it cannot abort the next session's input.
4. Stop freezes recorded time, enters flushing, feeds the capture tail, then sends
   FLUSH. Flush inactivity has a 45-second deadline, refreshed by protocol events.
   Timeout preserves available text and marks diarization identity unreliable.
5. Completion runs once. Failure cancels deadlines and work, aborts capture,
   detaches/terminates the engine, finalizes received text and attempts a checkpoint.
   It does not start post-session AI generation. Unexpected exit during recording
   is an error even with exit status zero; normal file/flush exit zero completes.
6. `EngineProcess` serializes stdout reads and its exit drain. Main-queue FIFO
   delivery places termination after decoded output, including an EOF line without
   a newline. Explicit retirement clears the delegate, discarding old output.
7. File decoding creates a distinct WAV per request. Cancellation is checked before
   work, during decoding and before returning. The decoder removes failed output;
   the coordinator removes accepted output on completion/cancellation/failure and
   discards output returned late by a non-cooperative cancelled preparation task.
8. Live segments remain available for post-session corrections while the capture
   instance is retained. Its unique directory is removed when that instance is
   released. Crash leftovers and legacy shared temporary directories are not swept.
9. Checkpoints and final save update one Markdown file until reset. A failed write
   retains the last successful file pointer and exposes `lastError`. Persisted IDs,
   exact word timing/confidence and crash recovery still require a future versioned
   session document; Markdown remains a display representation.

Starting/cancelling a countdown does not replace the displayed transcript or
invalidate its pending summary. Actual recording start is the session boundary.

## Regression evidence

`TranscriptArchiveTests.testLongSessionExportReopensEveryLineAndKeepsTranslationsOnTheirSource`
exports/reopens 99:59, 100:00, 120:00 and 720:00. Before the fix, only the first row
reopened and its translation was overwritten by the last omitted row's translation.
The importer now accepts the exporter's unbounded minute field.

`SessionEngineAdapterTests.testImmediateFileExitDeliversBufferedEventsBeforeCompletion`
uses a real shell subprocess producing 1,000 segment barriers and an unterminated
final progress line. Before stdout/exit ordering was fixed, the initial reproduction
delivered only 914 barriers before completion. The corrected implementation delivers
all barriers and the final progress event before completion. The second adapter test
checks live READY → feed → FLUSH → exit ordering.

`SessionCoordinatorTests` covers tail-before-flush, pause accounting, duplicate
completion, launch/capture/engine failures, startup and flush deadlines, suspended
capture cancellation, watchdog replacement, countdown cancellation and a cancelled
import finishing or failing during the next import. `SessionArchiveWriterTests`
uses real temporary files for checkpoint reuse, reset, collisions, write failure,
retry and rename with a companion summary.

`SessionOneShotTranscriberTests` runs real processes to verify forced-language
output, cancellation before launch, cancellation after launch and timeout without
applying a partial result.

## Verification

From `apps/macos`:

```sh
swift test
swiftc -parse-as-library Sovereign/Audio/AudioDecode.swift \
  Sovereign/Audio/Resampler.swift Sovereign/Audio/WavWriter.swift \
  Tests/AudioDecodeLimitTests.swift -o /tmp/madi-audio-decode-tests
/tmp/madi-audio-decode-tests
```

The native decode test generates its own audio. It checks bounds, concurrent
import isolation, cancellation and cleanup after an empty-input failure. CI's
`swift-tests` job runs both commands. The source-only-app job separately compiles
the UI and concrete capture adapter.

Local 2026-10-06 results and intermediate failure reproductions are retained under
`_quark/session-refactor-2026-10-06/`: 709 Swift tests, 707 passed and two existing
capture-fixture skips; native decode checks passed; final source-only app build,
bundle verification and version consistency passed. No release was published.
Hardware permission dialogs, actual input
switching/disconnection, multi-hour capture, 8 GB pressure and translation/summary
quality require release-candidate validation on devices. Unit/stub-process tests
and an app build do not establish those outcomes.
