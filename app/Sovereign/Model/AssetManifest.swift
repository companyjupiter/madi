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
    /// sha256/size = the shipping large-v3-turbo Q8 safetensors (verified asset).
    /// TODO(hosting): url is a placeholder until the CDN bucket exists.
    static let model = RemoteAsset(
        name: "model.safetensors",
        url: URL(string: "https://CHANGE-ME.example/sovereign/model.safetensors")!,
        sha256: "542566a422ae4f3fd23f1ba11add198fca01bbf82e66e6a2857b3f608b1eb9d1",
        sizeBytes: 1_617_824_864
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

    /// Fast launch check: exists + exact size (hashing 1.5 GB at every launch
    /// would cost seconds; the full SHA-256 runs once, right after download).
    static func modelIsValid() -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: modelURL.path),
              let size = attrs[.size] as? Int64 else {
            // attributesOfItem on a symlink describes the LINK; resolve for dev seeds
            if let resolved = try? FileManager.default.destinationOfSymbolicLink(atPath: modelURL.path),
               let a2 = try? FileManager.default.attributesOfItem(atPath: resolved),
               let s2 = a2[.size] as? Int64 { return s2 == model.sizeBytes }
            return false
        }
        if size == model.sizeBytes { return true }
        // symlinked dev seed: size is the link length — resolve and re-check
        if let resolved = try? FileManager.default.destinationOfSymbolicLink(atPath: modelURL.path),
           let a2 = try? FileManager.default.attributesOfItem(atPath: resolved),
           let s2 = a2[.size] as? Int64 { return s2 == model.sizeBytes }
        return false
    }

    /// Full integrity check — call after a download completes.
    static func modelHashMatches() -> Bool {
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
