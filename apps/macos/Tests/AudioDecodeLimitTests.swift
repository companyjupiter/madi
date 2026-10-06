// AudioDecodeLimitTests.swift — bounds checks for file import transcoding.
//
// Build standalone:
//   swiftc -parse-as-library Sovereign/Audio/AudioDecode.swift \
//          Sovereign/Audio/Resampler.swift Sovereign/Audio/WavWriter.swift \
//          Tests/AudioDecodeLimitTests.swift -o /tmp/adtest && /tmp/adtest

import AVFoundation
import Foundation

@main
struct AudioDecodeLimitTests {
    static func main() async {
        var failures = 0
        func check(_ cond: Bool, _ msg: String) {
            if !cond { failures += 1; print("FAIL: \(msg)") }
        }
        func accepts(bytes: Int64?, frames: AVAudioFramePosition, rate: Double) -> Bool {
            do {
                try AudioDecode.validateImportBounds(inputBytes: bytes, sourceFrames: frames, sampleRate: rate)
                return true
            } catch {
                return false
            }
        }

        check(accepts(bytes: 10 * 1024 * 1024, frames: 60 * 48_000, rate: 48_000),
              "accepts a normal one-minute import")
        check(!accepts(bytes: AudioDecode.maxInputBytes + 1, frames: 60 * 48_000, rate: 48_000),
              "rejects oversized source files")
        check(!accepts(bytes: 10 * 1024 * 1024,
                       frames: AVAudioFramePosition((AudioDecode.maxDecodedSeconds + 1) * 48_000),
                       rate: 48_000),
              "rejects over-duration source files")
        check(!accepts(bytes: 10 * 1024 * 1024, frames: 60 * 48_000, rate: 0),
              "rejects invalid sample rates")
        // video container: bytes are picture, only the duration cap applies
        check((try? AudioDecode.validateImportBounds(inputBytes: 7 * 1024 * 1024 * 1024, sourceFrames: 872 * 48_000,
                                                     sampleRate: 48_000, videoContainer: true)) != nil,
              "accepts a 7 GB video whose audio is 14.5 minutes")
        check((try? AudioDecode.validateImportBounds(inputBytes: 7 * 1024 * 1024 * 1024,
                                                     sourceFrames: AVAudioFramePosition((AudioDecode.maxDecodedSeconds + 1) * 48_000),
                                                     sampleRate: 48_000, videoContainer: true)) == nil,
              "still rejects an over-duration video")
        check(AudioDecode.reason(NSError(domain: "AudioDecode", code: 3)) == "파일이 64 GB를 넘습니다", "reason text for the byte cap")
        check(accepts(bytes: 12 * 1024 * 1024 * 1024, frames: 3600 * 48_000, rate: 48_000), "accepts a 12 GB one-hour audio-only file")

        // The actual native decoder, using generated audio only: overlapping
        // imports must not overwrite one shared WAV, and failures leave no temp.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let a = root.appendingPathComponent("a.wav"), b = root.appendingPathComponent("b.wav")
            try WavWriter.write(samples: Array(repeating: 1000, count: 16000), to: a)
            try WavWriter.write(samples: Array(repeating: -2000, count: 8000), to: b)
            async let first = AudioDecode.toWav16k(a)
            async let second = AudioDecode.toWav16k(b)
            let (firstURL, secondURL) = try await (first, second)
            defer {
                try? FileManager.default.removeItem(at: firstURL)
                try? FileManager.default.removeItem(at: secondURL)
            }
            check(firstURL != secondURL, "concurrent decodes own distinct WAVs")
            let firstData = try Data(contentsOf: firstURL), secondData = try Data(contentsOf: secondURL)
            check(firstData.count > 44 && secondData.count > 44, "both imports retain PCM")
            check(firstData != secondData, "second import cannot overwrite first audio")
            let cancelled = Task.detached {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await AudioDecode.toWav16k(a)
            }
            do {
                let unexpected = try await cancelled.value
                try? FileManager.default.removeItem(at: unexpected)
                check(false, "cancelled decode must throw")
            } catch is CancellationError { } catch { check(false, "cancellation error identity") }

            func decodedTemps() throws -> Set<String> {
                Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
                    .filter { $0.hasPrefix("sovereign-decode-") })
            }
            let before = try decodedTemps()
            let empty = root.appendingPathComponent("empty.wav")
            try WavWriter.write(samples: [], to: empty)
            do {
                let unexpected = try await AudioDecode.toWav16k(empty)
                try? FileManager.default.removeItem(at: unexpected)
                check(false, "empty audio must fail")
            } catch { }
            let after = try decodedTemps()
            check(before == after, "failed decode removes its partial WAV")
        } catch { check(false, "native decode fixture: \(error)") }

        if failures == 0 { print("✅ AudioDecode limits, isolation, cancellation, cleanup: all checks passed") }
        else { print("❌ \(failures) failure(s)"); exit(1) }
    }
}
