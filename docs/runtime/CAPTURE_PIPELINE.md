# Post-converter live capture and owned WAVs

`madi-core::capture_stream` ports the shipping `AudioCapture.swift` path after
conversion to 16 kHz mono PCM16. `madi-platform::capture_pipeline` writes its
outputs to one owned temporary directory. The same pipeline is now exercised
from the linked native capture replay and the relocated Tauri app's debug probe.
The native live effect executor is connected and verified with real ASR replay
(`LIVE_SESSION.md`); the product recording button remains unconnected.

## Source behavior preserved

- Mic/system inputs go directly to the segmenter. Both-source capture sums the
  shared prefix and clamps each sample to Int16. A source buffered beyond 32,000
  samples, with no counterpart, is consumed solo. Exactly 32,000 does not flush.
- Meter RMS accumulates normalized Int16 values in Double, takes the square root,
  multiplies by three, clamps to one and only then converts to Float. Mixed
  buffers use their mixed RMS. Stop's unmatched tail reports level zero.
- Pause changes no native device state. Delivered paused buffers report level
  zero and do not enter the timeline. A both-source paused delivery clears both
  queues; calling pause without any subsequent delivery leaves the pending tail
  available to stop, matching the original ordering.
- Normal stop disables further ingestion, clears pause, consumes the longer
  unmatched source tail, then flushes the segmenter. Abort disables ingestion,
  drops queued PCM and resets segmentation without a tail. Both reject late PCM.
- Closed segments are named `seg00000.wav`, `seg00001.wav`, etc. A failed write
  still consumes that index. The segmenter preserves the verified overlap,
  early-flush, speech and short-first-window rules.
- After a cut the preview counter is reset, then the **whole incoming buffer**
  is counted, including samples before the cut. Preview admission uses
  `counter >= interval` and `pending > interval / 2`. Slots rotate 1, 2, 0.
  Previews are emitted after any committed segments from the same delivery.
- Property changes preserve pending audio. Starting again resets segmentation
  and source queues, but not the preview slot/counter or pause flag. Abort resets
  the preview counter but retains the slot. The controller normally creates a
  fresh capture instance per session; the differential also covers reuse.

## Resource and execution contract

Native callbacks must enqueue PCM only. A serial blocking worker runs ingestion,
controls and file writes so ordering is stable without blocking AppKit. Start
the pipeline before opening native inputs: microphone data can arrive while
system capture is still starting. Native `Started`, not pipeline construction,
establishes input readiness.

For normal shutdown, stop the native capture and drain its accepted events
through `Stopped`; process the pipeline tail and successful segment files; only
then acknowledge `Session::capture_stopped` so FLUSH cannot overtake the tail.
Failed/cancelled admission uses `abort`, followed by native teardown, and does not
feed a final segment. The live executor applies the existing session generation
and engine-token checks to these deliveries.

Each pipeline creates a unique directory under a trusted scratch parent. There
is no arbitrary-path ownership constructor. `OwnedWav` leases retain that same
directory while engine or correction jobs still use a file; dropping the last
lease removes only that directory. Retiring capture cannot remove a later
session's files or an original imported source.

Writes use a canonical 44-byte RIFF header and little-endian PCM, staged in the
owned directory and atomically published. A failed publication emits a diagnostic
instead of a successful file notification; it leaves the prior destination
intact. Preview failure remains best-effort, as in the original. Three rotating
preview paths preserve the source policy; a lease extends directory lifetime,
not immutability of a reused preview slot. Committed segment paths are retained
for transcription correction until their jobs/session release ownership.

## Evidence and remaining acceptance

`scripts/check_capture_pipeline_parity.py` compares 113 sequences and 6,337
operations against the actual shipping `AudioCapture` methods. The generated
oracle appends a same-file extension for private access; it retains every byte
of the original implementation. Only native device admission is omitted. The
small `SessionCapture` protocol is extracted unchanged, and an unused label-only
`UILanguage` stub satisfies the UI dependency. No processing method is replaced.

The native comparison matches 3,164 Float meter events, 727 committed segments,
519 previews and 140,680,014 WAV bytes, including exact event order, filenames,
offset bits, final files and directory cleanup. It includes five minutes of
synthetic alternating both-source PCM. Windows CI uses the pinned Swift result;
it does not claim Windows audio hardware support.

Five core regressions cover mixing saturation, the strict stall boundary,
pause/stop ordering, abort/late PCM and whole-buffer preview accounting. Three
platform regressions cover retained ownership, failed publication/index advance
and preview rotation/abort. Mutation checks change the stall comparison and
preview counter independently; their targeted regressions must fail and pass
again after restoration.

The eight native converter cases now also compare their owned WAV outputs and
directory cleanup. The installed-bundle probe must produce the expected segment
WAV and remove its owned directory using only the packaged runtime.

Native replay through the resident ASR executor now passes; see `LIVE_SESSION.md`.
Still **NOT_RUN**: full product live scheduling, recording UI, real microphone/system
input, permission denial, physical device switching, complete UI/UX parity and
recording latency/memory acceptance. Release remains disabled.
