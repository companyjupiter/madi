// AssetManifestTests.swift — focused integrity checks for model files.
//
// Build standalone:
//   swiftc -parse-as-library Sovereign/Model/AssetManifest.swift \
//          Tests/AssetManifestTests.swift -o /tmp/amtest && /tmp/amtest

import Foundation

@main
struct AssetManifestTests {
    static func main() throws {
        var failures = 0
        func check(_ cond: Bool, _ msg: String) {
            if !cond { failures += 1; print("FAIL: \(msg)") }
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("asset-manifest-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let good = dir.appendingPathComponent("model.bin")
        let badSameSize = dir.appendingPathComponent("bad-same-size.bin")
        try Data("trusted model bytes".utf8).write(to: good)
        try Data("tampered model byte".utf8).write(to: badSameSize)

        let expectedSize = Int64(try Data(contentsOf: good).count)
        let expectedHash = try AssetManifest.sha256(of: good)

        check(AssetManifest.modelFileIsValid(at: good, expectedSize: expectedSize, expectedSHA256: expectedHash),
              "accepts exact size + hash")
        check(!AssetManifest.modelFileIsValid(at: badSameSize, expectedSize: expectedSize, expectedSHA256: expectedHash),
              "rejects same-size wrong-content model")

        let link = dir.appendingPathComponent("model-link.bin")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: good.path)
        check(!AssetManifest.modelFileIsValid(at: link, expectedSize: expectedSize, expectedSHA256: expectedHash),
              "rejects symlink model path")

        if failures == 0 { print("✅ AssetManifest: all checks passed") }
        else { print("❌ \(failures) failure(s)"); exit(1) }
    }
}
