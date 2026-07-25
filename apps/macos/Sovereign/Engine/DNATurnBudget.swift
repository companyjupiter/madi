// DNATurnBudget.swift — how long ONE DNA3 turn may take before the broker's
// watchdog declares the lane wedged. PURE logic (Foundation only) so it is
// unit-testable.
//
// Why a derived budget and not a constant: the only failure this guards is the
// engine never emitting its "[perf] generation" terminator, which permanently
// wedges every DNA client (live captions, interim captions, the action rail and
// the summary all share ONE resident process). Recovery costs a process restart
// and a model reload, so a FALSE positive is expensive — the budget has to sit
// well above the slowest LEGITIMATE turn, not near the median.
//
// Upper bound of a legitimate turn = prefill(prompt) + decode(SOV_NSTEPS), both
// at the model's measured throughput:
//
//   profile   | median prefill | median decode   (docs/LIVE_TRANSLATE.md, 2026-07-21)
//   DNA3.0-4B |   414.8 tok/s  |   67.3 tok/s
//   DNA3.0-2B |   998.7 tok/s  |  132.8 tok/s
//
// The rates below are rounded DOWN from those medians (a median is beaten half
// the time), then the modelled time is multiplied by `contentionFactor` because
// the DNA process shares the GPU with whisper decode and diarization, and a
// thermally throttled M1 Air is the minimum spec.
//
// Prompt tokens are estimated as prompt BYTES. That is the engine's own
// invariant ("#tokens ≤ #input-bytes", main.zig sizing its token buffer), so it
// over-estimates — which is the safe direction here.

import Foundation

enum DNATurnBudget {
    struct Rates: Equatable {
        let prefill: Double     // tok/s
        let decode: Double      // tok/s
    }

    /// Conservative floors under the measured medians.
    static let rates4B = Rates(prefill: 300, decode: 63)
    static let rates2B = Rates(prefill: 600, decode: 125)

    /// GPU contention (whisper + diar on the same device) and thermal throttling.
    static let contentionFactor = 3.0
    /// Pipe/scheduling overhead that does not scale with the prompt.
    static let fixedOverhead: TimeInterval = 5
    /// A short prompt on a fast model must still get a sane grace period.
    static let minimum: TimeInterval = 20
    /// Sanity clamp — past this the lane is unusable anyway.
    static let maximum: TimeInterval = 180

    /// Rates for the engine the broker actually launched. The bundled binaries
    /// are named `translate-engine-4b` / `translate-engine-2b`
    /// (AssetManifest.engineExecutableName); anything else falls back to the
    /// SLOWER profile, so an unrecognised engine gets the more generous budget.
    static func rates(forEnginePath path: String) -> Rates {
        path.hasSuffix("-2b") ? rates2B : rates4B
    }

    /// Seconds one turn may take. `steps` is the engine's own generation cap
    /// (the broker pins SOV_NSTEPS), so this is the engine's worst case by
    /// construction, not a guess about how long a reply "should" be.
    static func seconds(promptBytes: Int, steps: Int, rates: Rates) -> TimeInterval {
        let modelled = Double(max(promptBytes, 0)) / rates.prefill
                     + Double(max(steps, 0)) / rates.decode
        return min(max(modelled * contentionFactor + fixedOverhead, minimum), maximum)
    }

    /// Test/field override in MILLISECONDS. Present so the watchdog path can be
    /// exercised in a unit test without a 30 s wait, and so a wedge can be
    /// reproduced in the field without a rebuild.
    static func override(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> TimeInterval? {
        guard let raw = environment["MADI_DNA_TIMEOUT_MS"], let ms = Double(raw), ms > 0 else { return nil }
        return ms / 1000
    }
}
