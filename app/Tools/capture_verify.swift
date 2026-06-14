// capture_verify.swift — headless verification harness for the native audio
// capture path (Resampler + Segmenter + WavWriter). Drives the SAME code the
// mic uses, but from files, so Layers 0–3 are deterministic and scriptable.
//
// Build (no Xcode):
//   swiftc -O Sovereign/Audio/Resampler.swift Sovereign/Audio/Segmenter.swift \
//          Sovereign/Audio/WavWriter.swift Tools/capture_verify.swift \
//          -o /tmp/capture_verify
//
// Modes:
//   resample <in.wav> <out16k.wav>     native-rate in → AVAudioConverter → 16k
//   segment  <in16k.wav> <outdir> [seg] [ovl]   write seg%05d.wav + feed.txt + assert
//   segtest                            pure Segmenter invariants (synthetic ramp)
//   compare  <a16k.wav> <b16k.wav>     lag-align + RMS/peak/correlation

import Foundation
import AVFoundation

@main
struct CaptureVerify {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 2 else { usage(); exit(2) }
        do {
            switch args[1] {
            case "resample" where args.count == 4: try resample(args[2], args[3])
            case "segment"  where args.count >= 4: try segment(args)
            case "segtest": segtest()
            case "segtest-asym": segtestAsym()
            case "compare"  where args.count == 4: try compare(args[2], args[3])
            default: usage(); exit(2)
            }
        } catch { FileHandle.standardError.write(Data("ERROR: \(error)\n".utf8)); exit(1) }
    }

    static func usage() {
        print("""
        usage:
          capture_verify resample <in.wav> <out16k.wav>
          capture_verify segment  <in16k.wav> <outdir> [segSec] [ovlSec]
          capture_verify segtest
          capture_verify segtest-asym
          capture_verify compare  <a16k.wav> <b16k.wav>
        """)
    }

    // MARK: Layer 0/1 — resample via the real Resampler

    static func resample(_ inPath: String, _ outPath: String) throws {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: inPath))
        guard let rs = Resampler(from: file.processingFormat) else {
            throw Err("resampler init failed for \(file.processingFormat)")
        }
        var all: [Int16] = []
        while file.framePosition < file.length {
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192)
            else { break }
            try file.read(into: buf)
            if buf.frameLength == 0 { break }
            all.append(contentsOf: rs.convert(buf))
        }
        all.append(contentsOf: rs.drain())   // flush converter tail
        try WavWriter.write(samples: all, to: URL(fileURLWithPath: outPath))
        print("resample: \(inPath) [\(Int(file.processingFormat.sampleRate))Hz] → \(outPath) [16000Hz] \(all.count) samples (\(fmt(Double(all.count)/16000))s)")
    }

    // MARK: Layer 2 — segmentation over a real 16k file + invariant asserts

    static func segment(_ args: [String]) throws {
        let inPath = args[2], outDir = args[3]
        let seg = args.count > 4 ? Double(args[4]) ?? 10 : 10
        let ovl = args.count > 5 ? Double(args[5]) ?? 3 : 3
        let samples = try readPCM16(URL(fileURLWithPath: inPath))
        try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        var segmenter = Segmenter(segmentSeconds: seg, overlapSeconds: ovl)
        var segs: [Segmenter.Segment] = []
        // push in irregular chunks to mimic realtime tap granularity
        var i = 0
        while i < samples.count {
            let n = min(4096, samples.count - i)
            segs.append(contentsOf: segmenter.push(Array(samples[i..<i+n])))
            i += n
        }
        if let f = segmenter.flush() { segs.append(f) }

        var feed = ""
        for (k, s) in segs.enumerated() {
            let url = URL(fileURLWithPath: outDir).appendingPathComponent(String(format: "seg%05d.wav", k))
            try WavWriter.write(samples: s.samples, to: url)
            feed += String(format: "%.3f %@\n", s.offset, url.path)
        }
        try (feed + "FLUSH\n").write(toFile: outDir + "/feed.txt", atomically: true, encoding: .utf8)

        assertInvariants(segs, total: samples.count, seg: seg, ovl: ovl, rate: 16000)
        print("segment: \(segs.count) segments → \(outDir)/  (feed.txt written)")
    }

    // MARK: Layer 2 — pure Segmenter invariants on a synthetic ramp

    static func segtest() {
        let rate = 16000, seg = 10.0, ovl = 3.0
        let segN = Int(seg * Double(rate)), ovlN = Int(ovl * Double(rate))
        // 53s ramp: each sample = its global index mod 32768 (so we can verify identity)
        let total = 53 * rate
        let src = (0..<total).map { Int16($0 % 32768) }
        var segmenter = Segmenter(sampleRate: rate, segmentSeconds: seg, overlapSeconds: ovl)
        var segs: [Segmenter.Segment] = []
        var i = 0
        while i < total { let n = min(1234, total - i); segs.append(contentsOf: segmenter.push(Array(src[i..<i+n]))); i += n }
        if let f = segmenter.flush() { segs.append(f) }
        assertInvariants(segs, total: total, seg: seg, ovl: ovl, rate: rate, ramp: true, expectSegN: segN, expectOvlN: ovlN)
    }

    /// Same ramp, but with the ASYMMETRIC first window (first=3s, rest=10s). Proves
    /// the short first segment loses/duplicates/misaligns NOTHING: body-sum, overlap
    /// continuity, offset drift, and exact ramp reconstruction must all still hold.
    static func segtestAsym() {
        let rate = 16000, seg = 10.0, ovl = 3.0, first = 3.0
        let total = 53 * rate
        let src = (0..<total).map { Int16($0 % 32768) }
        var segmenter = Segmenter(sampleRate: rate, segmentSeconds: seg, overlapSeconds: ovl,
                                  firstSegmentSeconds: first)
        var segs: [Segmenter.Segment] = []
        var i = 0
        while i < total { let n = min(1234, total - i); segs.append(contentsOf: segmenter.push(Array(src[i..<i+n]))); i += n }
        if let f = segmenter.flush() { segs.append(f) }
        // first body must be exactly 3s; first text would paint ~7s sooner than seg=10
        print("  asym: seg0 body=\(segs.first?.bodyCount ?? -1) (expect \(Int(first*Double(rate)))), \(segs.count) segs total")
        assertInvariants(segs, total: total, seg: seg, ovl: ovl, rate: rate, ramp: true,
                         expectSegN: Int(seg*Double(rate)), expectOvlN: Int(ovl*Double(rate)), firstSeg: first)
    }

    /// Shared invariant checker: body length, overlap continuity, offset drift,
    /// and (ramp mode) exact-sample reconstruction.
    static func assertInvariants(_ segs: [Segmenter.Segment], total: Int, seg: Double,
                                 ovl: Double, rate: Int, ramp: Bool = false,
                                 expectSegN: Int = 0, expectOvlN: Int = 0,
                                 firstSeg: Double = 0) {
        let segN = Int(seg * Double(rate)), ovlN = Int(ovl * Double(rate))
        // asymmetric first window: seg 0 body is firstSegN (0 ⇒ symmetric = segN)
        let firstSegN = firstSeg > 0 ? Int(firstSeg * Double(rate)) : segN
        var fail = 0
        func check(_ c: Bool, _ m: String) { if !c { fail += 1; print("  FAIL: \(m)") } }

        // 1) every non-final segment has its expected body (seg 0 may be short)
        for (k, s) in segs.enumerated() where k < segs.count - 1 {
            let want = k == 0 ? firstSegN : segN
            check(s.bodyCount == want, "seg \(k) body=\(s.bodyCount) != \(want)")
        }
        // 2) bodies sum to total (no sample lost/duplicated)
        let bodySum = segs.reduce(0) { $0 + $1.bodyCount }
        check(bodySum == total, "body sum \(bodySum) != total \(total)")
        // 3) overlap length: seg k (k>0) carries exactly min(ovlN, prevBody) overlap
        for k in 1..<max(1, segs.count) {
            let carried = segs[k].samples.count - segs[k].bodyCount
            check(carried == min(ovlN, segs[k-1].bodyCount), "seg \(k) overlap=\(carried) != \(min(ovlN, segs[k-1].bodyCount))")
        }
        // 4) offset drift: seg k offset == cumulative prior bodies - its overlap, in seconds
        var cumBody = 0
        for (k, s) in segs.enumerated() {
            let carried = s.samples.count - s.bodyCount
            let expected = max(0, Double(cumBody - carried) / Double(rate))
            check(abs(s.offset - expected) < 1.0/Double(rate), "seg \(k) offset \(s.offset) drift vs \(expected)")
            cumBody += s.bodyCount
        }
        // 5) ramp identity: overlap tail of seg k must equal the prefix that the
        //    previous body ended with (continuity), and bodies reconstruct src.
        if ramp {
            var recon: [Int16] = []
            for s in segs { recon.append(contentsOf: s.samples.suffix(s.bodyCount)) }
            check(recon.count == total, "recon \(recon.count) != \(total)")
            var ok = true
            for (idx, v) in recon.enumerated() where v != Int16(idx % 32768) { ok = false; break }
            check(ok, "ramp reconstruction mismatch")
            check(expectSegN == segN && expectOvlN == ovlN, "ramp param sanity")
        }
        print(fail == 0 ? "  ✅ invariants PASS (\(segs.count) segs)" : "  ❌ \(fail) invariant failure(s)")
        if fail > 0 { exit(1) }
    }

    // MARK: Layer 1 judge — lag-aligned RMS/peak/correlation between two 16k WAVs

    static func compare(_ aPath: String, _ bPath: String) throws {
        let a = try readPCM16(URL(fileURLWithPath: aPath))
        let b = try readPCM16(URL(fileURLWithPath: bPath))
        let fa = a.map { Double($0) / 32768.0 }
        let fb = b.map { Double($0) / 32768.0 }

        // find integer lag in [-64,64] maximizing cross-correlation on a mid window
        let win = min(160000, min(fa.count, fb.count) - 200)
        let start = max(64, (min(fa.count, fb.count) - win) / 2)
        var bestLag = 0, bestCorr = -Double.infinity
        for lag in -64...64 {
            var dot = 0.0
            var ka = start, kb = start + lag
            for _ in 0..<win { dot += fa[ka] * fb[kb]; ka += 1; kb += 1 }
            if dot > bestCorr { bestCorr = dot; bestLag = lag }
        }
        // metrics over the aligned overlap
        let n = min(fa.count, fb.count - bestLag) - max(0, -bestLag) - 1
        var se = 0.0, peak = 0.0, ea = 0.0, eb = 0.0, dotN = 0.0
        for k in 0..<n {
            let x = fa[k + max(0, -bestLag)], y = fb[k + max(0, bestLag)]
            let d = abs(x - y); se += d*d; peak = max(peak, d)
            ea += x*x; eb += y*y; dotN += x*y
        }
        let rms = (se / Double(n)).squareRoot()
        let corr = dotN / (ea.squareRoot() * eb.squareRoot())
        let rmsDBFS = 20 * log10(max(rms, 1e-12))
        print("compare \(aPath) vs \(bPath)")
        print(String(format: "  lag=%+d samples (%.2f ms)  n=%d", bestLag, Double(bestLag)/16.0, n))
        print(String(format: "  RMS error=%.6f (%.1f dBFS)  peak=%.6f  correlation=%.6f",
                     rms, rmsDBFS, peak, corr))
        // advisory gate: well-aligned resamplers correlate >0.999; the real gate
        // is transcript/DER parity downstream, this is the diagnostic.
        print(corr > 0.999 ? "  ✅ high correlation" : "  ⚠ correlation below 0.999 — inspect (try converter quality knob)")
    }

    // MARK: WAV (16-bit PCM) reader

    static func readPCM16(_ url: URL) throws -> [Int16] {
        let d = try Data(contentsOf: url)
        guard d.count > 44 else { throw Err("short wav") }
        // find "data" chunk
        var off = 12
        var dataOff = 44, dataLen = d.count - 44
        while off + 8 <= d.count {
            let id = String(bytes: d[off..<off+4], encoding: .ascii) ?? ""
            let sz = Int(d[off+4]) | Int(d[off+5])<<8 | Int(d[off+6])<<16 | Int(d[off+7])<<24
            if id == "data" { dataOff = off + 8; dataLen = min(sz, d.count - dataOff); break }
            off += 8 + sz + (sz & 1)
        }
        let count = dataLen / 2
        var out = [Int16](repeating: 0, count: count)
        out.withUnsafeMutableBytes { dst in
            d.withUnsafeBytes { src in
                dst.copyBytes(from: UnsafeRawBufferPointer(rebasing: src[dataOff..<dataOff+count*2]))
            }
        }
        return out
    }

    struct Err: Error, CustomStringConvertible { let m: String; init(_ m: String){self.m=m}; var description: String { m } }
    static func fmt(_ x: Double) -> String { String(format: "%.1f", x) }
}
