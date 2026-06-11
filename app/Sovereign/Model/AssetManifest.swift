// AssetManifest.swift — what the app downloads on first run and where it lives.
//
// Small assets (pyannote/silero/resnet/bpe/mel/conv/pos_emb/tokenizer) ship
// INSIDE the bundle (Resources/assets-small). Only the 1.5 GB model.safetensors
// is fetched on first run into Application Support, verified by SHA-256.
//
// TODO(hosting): fill in `url` + `sha256` once the model is hosted (R2/S3/CDN)
// and pin the version. Bumping the model = ship a new app build with new hashes.

import Foundation
import CryptoKit

struct RemoteAsset {
    let name: String
    let url: URL
    let sha256: String        // lowercase hex of the expected digest
    let sizeBytes: Int64
}

enum AssetManifest {
    /// The large model fetched on first run.
    static let model = RemoteAsset(
        name: "model.safetensors",
        url: URL(string: "https://CHANGE-ME.example/sovereign/model.safetensors")!,
        sha256: "0000000000000000000000000000000000000000000000000000000000000000",
        sizeBytes: 1_542_000_000
    )

    /// App Support root: ~/Library/Application Support/Sovereign/
    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Sovereign", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var modelURL: URL { supportDir.appendingPathComponent(model.name) }

    /// Bundled small assets dir (engine cwd for relative loads).
    static var bundledAssetsDir: URL {
        Bundle.main.resourceURL!.appendingPathComponent("assets-small", isDirectory: true)
    }
    static var bundledBPE: URL { bundledAssetsDir.appendingPathComponent("WHISPER_BPE.bin") }

    /// True iff the model exists locally AND its digest matches the manifest.
    static func modelIsValid() -> Bool {
        guard FileManager.default.fileExists(atPath: modelURL.path) else { return false }
        guard let digest = try? sha256(of: modelURL) else { return false }
        return digest == model.sha256
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while case let chunk = handle.readData(ofLength: 8 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
