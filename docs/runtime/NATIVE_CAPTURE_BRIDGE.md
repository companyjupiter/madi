# In-process macOS capture boundary

`madi-platform::audio_capture` links a small Swift static library into the Rust
host. It retains AVAudioEngine, ScreenCaptureKit and the unchanged shipping
`Resampler.swift` / `AudioDevices.swift`. Mixing, pauses, segmentation, WAV
ownership and live engine scheduling remain Rust responsibilities; they are not
implemented by this bridge. The recording button is not connected yet.

This follows the migration plan's allowance for a thin native API bridge. The
capture code must run in Madi's process so ScreenCaptureKit's
[`excludesCurrentProcessAudio`](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/excludescurrentprocessaudio)
continues to exclude the app's own output. The existing decoder remains a helper
because its file-only work has no process-audio exclusion requirement.

## Ownership and ordering

- Rust allocates non-reused capture IDs. Neither direction stores the other
  language's object pointer. Swift borrows PCM/string pointers only during the
  callback; Rust copies accepted data before returning.
- Start, stop and device-switch commands enqueue on the main dispatch queue.
  Swift retains each endpoint until its own asynchronous start completes and
  its own SCStream stop returns. A stop during startup cancels that exact task;
  a late completion cannot close a later capture.
- `Started` means both requested input paths have actually started. A queued
  start command is not readiness. Microphone buffers may arrive while system
  capture is starting, as in the original AudioCapture.
- Tap and ScreenCaptureKit callbacks convert on their original serial paths.
  Main-queue delivery preserves submission order. Old microphone-tap callbacks
  are rejected after a switch, and all late samples are rejected after stop.
- The native main-queue ingress and the Rust receiver each allow at most 320,000
  queued samples (20 seconds of mono PCM). Overflow reports an explicit fault
  and stops that capture. Audio is never silently discarded to keep recording.
  Native callbacks perform no Rust file or engine work.
- The callback sequence ends with `Stopped`; the Rust receiver then closes.
  A deliberate drop removes only its own receiver and requests native stop.
  Application shutdown must keep the main run loop alive for an acknowledged
  stop. The future live executor must drain capture, emit its Rust mix/segment
  tail, and only then acknowledge `Session::capture_stopped` and send FLUSH.

Device switching retains the original selected/default-device binding and
converter recreation. Invalid input formats fail before installing a tap.
Hardware switch, disconnect, permission denial and an actual pending SCStream
start/stop race remain device acceptance work; the synthetic gate does not claim
to exercise them.

## Build and packaging

The platform build script compiles `libMadiAudioCapture.a` for macOS 14 and links
Apple system frameworks and the OS Swift runtime. The platform's examples/tests
and final Tauri executable explicitly include `/usr/lib/swift` as a runtime
search path. This fixes an observed first-run dyld failure for
`libswift_Concurrency.dylib`; no Xcode or Homebrew dylib path is shipped.

The candidate's microphone, screen-capture and audio-capture usage strings match
the original Info.plist, and its signature includes the audio-input entitlement.
These declarations do not prove permission behavior. They are verified in the
copied, strict-signature-checked bundle before real device work.

The debug build exposes `--native-capture-replay <file>` only as a native CLI
package check. It does not create an audio engine, a screen stream or a window,
and requests no permissions. The replay entry points are excluded from the
Swift release build and Rust release API; the product release remains disabled.
No capture/replay command is added to WebView capabilities.

## Verification

`python3 scripts/check_capture_bridge_parity.py` generates 16/44.1/48/96 kHz mono
and stereo WAV inputs, each with speech-like, quiet, silent and saturated parts.
Both 4096- and 997-frame delivery are compared. The reference uses unchanged
shipping Resampler, Segmenter and WAV constants. The candidate uses the linked
native converter, bounded ingress, borrowed callback ABI, Rust receiver and
Rust segmenter, including converter drain and final tail.

Eight cases compare every PCM chunk length, full PCM SHA-256, segment PCM,
offset bits, body count and speech flag: 1,664,512 samples and 32 segments match
on the local Mac. Each case also cancels one simultaneous endpoint twice and
drops another; the surviving endpoint still matches. A missing-file case checks
failure followed by one terminal acknowledgement, without phantom readiness.
Two Rust regressions cover borrowed-buffer copying, identity isolation, bounded
queue overflow, single error and preservation of the terminal acknowledgement.

The relocated `.app` check invokes its own linked capture replay using only
system tools on PATH and compares PCM with the bundled decoder. It verifies
permission strings/entitlement, no developer dylib paths and strict signatures.
Local evidence is recorded in `../evidence/macos-native-capture-2026-11-04.json`.

Still **NOT_RUN**: microphone/system hardware, TCC prompts, physical device
switch/disconnect, system self-audio exclusion, real start/cancel races, long
recording performance and live recording UI. Windows capture remains unimplemented.
