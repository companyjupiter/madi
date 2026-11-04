# Live PCM windowing boundary

`madi-core::segmenter` ports the unchanged `Audio/Segmenter.swift` arithmetic.
It accepts converted PCM16 samples and emits bodies with their original overlap,
start offset and speech flag. Preview and final-tail access use the same state.
It does not open an input, resample audio, write files, feed an engine or start
recording. Those production connections remain required.

The pure type defaults to a symmetric 10-second first window, as the Swift
struct does. The production `AudioCapture` instead explicitly sets its first
window to 1.5 seconds; that asymmetric configuration is covered by the corpus.
A new instance resets the clock and analysis state. Valid property changes
preserve buffered audio and take effect on the next push, matching Swift.

The source behavior is more specific than a conventional VAD window cutter:

- Each whole incoming buffer is analyzed before any full windows are cut.
- An incomplete 10 ms analysis hop carries into the next push. Mean absolute
  PCM is compared against `max(200, 0.15 * peak)`; equality counts as speech.
- A cut updates the speech flag from remaining samples, but does not reset the
  peak, trailing silence or partial hop. The port preserves this behavior.
- Overlap is a suffix of the just-emitted body, never a suffix of its overlap
  plus body. This matters after a short first window or a short final flush.
- Early flush runs only if the push emitted no full windows, and requires
  speech, the minimum body and sufficient trailing silence shorter than the
  body. Disabled early flush reports the legacy `hadSpeech = true` behavior.
- An empty flush emits nothing; repeated flushes cannot duplicate a tail.

The native boundary rejects configurations that would create zero-sized full
windows, a zero-sized analysis hop, negative overlap or unrepresentable sample
counts. The Swift source can trap or loop for such invalid configurations.
This fail-closed policy is explicit and is not counted as equivalence for those
inputs. Rejected changes preserve the previous configuration and buffered PCM.

## Verification

`python3 scripts/check_segmenter_parity.py` compiles the original Swift source
with the original WAV constants and compares it to the Rust implementation.
Every emitted segment and preview is checked by full little-endian PCM SHA-256,
exact floating-point offset bits, body count, pending count and speech flag.
The frozen reference runs on Windows with `--rust-only`; all text/source hashes
use explicit UTF-8 and LF paths.

The corpus covers 225 sequences, 24,347 snapshots and 2,676 segments. It includes
shipping early-flush examples, 10 ms boundary fragments, Int16 extremes, quiet
speech, a retained loud peak, short first windows, oversized overlap, fractional
sample counts, changing settings with buffered audio, repeated flush, continued
push after flush and a two-minute synthetic capture. Sixteen legacy groups
verify identical segment PCM across delivery chunk sizes. Early flush is
intentionally not claimed to be fragmentation-invariant: the current source's
whole-buffer analysis makes those delivery boundaries observable.

Four Rust regressions cover overlap/preview/tail integrity, the exact speech
floor, the retained peak and invalid-change rollback. Resetting the peak at a
cut makes the quiet-speech regression fail; restoring the source behavior passes.
The pinned reference is `design/parity/segmenter-reference.json`.

## Required next connections

1. Add native sample delivery with the original converter/channel/mixing policy,
   including system audio, microphone choice and pause/drop behavior.
2. Preserve `AudioCapture` preview cadence, rotating preview files and unique
   per-session segment ownership. Keep final segments available for corrections;
   remove only the retired capture's own directory.
3. Execute the existing session effects with token-bound capture startup,
   pause/resume/stop/abort, engine readiness, deadlines and tail-before-FLUSH.
4. Connect the real recording UI and recording-disabled Settings state. Validate
   device permissions/switching, stop/pause/cancel, long captures and product
   timing using actual native inputs. Synthetic PCM parity cannot pass that gate.

Local candidate checks pass 101 Rust tests (16 core / 71 platform / 14 protocol),
four frontend tests, formatting and workspace clippy. Both live and pinned
segmenter gates pass; the source's quiet-speech mutation fails as expected.
Evidence: `../evidence/live-segmentation-2026-11-04.json`. The prior native-toolbar
CI receipt is independent of this new windowing layer.
