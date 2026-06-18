// AssetManifest.swift — what the app downloads on first run and where it lives.
//
// Small assets (pyannote/silero/resnet/bpe/mel/conv/pos_emb/tokenizer) ship
// INSIDE the bundle (Resources/assets-small). Only the ~830 MB Q8 model.safetensors
// is fetched on first run into Application Support, verified by SHA-256.
// (Q8 is 1.86x smaller than F16 — the old "1.5 GB" figure was the F16 model.)
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
    /// The large model fetched on first run — the pre-quantized Q8 build
    /// (bench/quantize_q8.py output), 1.86x smaller than F16 with proven zero
    /// quality change (engine loads its Q8 directly; WHASH weight-identity).
    /// sha256/size = the shipping Q8 safetensors.
    /// TODO(hosting): url is a placeholder until the CDN bucket exists.
    static let model = RemoteAsset(
        name: "model.q8.safetensors",
        url: URL(string: "https://CHANGE-ME.example/sovereign/model.q8.safetensors")!,
        sha256: "1014fd3ad4450a2e43e473eebbab485b165fd68cbe932372071d86c522bb5c8e",
        sizeBytes: 867_485_320
    )

    /// Live-translation model — DNA3.0-4B (Qwen3.5 base + Korean tuning), Q4_K_M
    /// GGUF (~2.6 GB). DELIBERATELY NOT bundled in the app/DMG: it would ~quadruple
    /// the download, and translation is opt-in. Fetched on demand into App Support
    /// via a button (TranslateModelDownloader) the first time the user enables it.
    /// TODO(hosting): url is a placeholder until the CDN bucket exists.
    static let translateModel = RemoteAsset(
        name: "DNA3.0-4B.i1-Q4_K_M.gguf",
        url: URL(string: "https://CHANGE-ME.example/sovereign/DNA3.0-4B.i1-Q4_K_M.gguf")!,
        sha256: "a00a837a797d95b23c31e2821855e89d6b931b9c80c59d7dd5dd219554590fd8",
        sizeBytes: 2_783_447_424
    )
    /// Always App Support (never bundled). The 1.1 MB engine binary IS bundled.
    static var translateModelURL: URL { supportDir.appendingPathComponent(translateModel.name) }
    /// Fast presence gate (size-only, symlinks resolved for the dev-seed path —
    /// like the main model launch gate).
    static func translateModelIsValid() -> Bool {
        let resolved = translateModelURL.resolvingSymlinksInPath()
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: resolved.path),
              let size = attrs[.size] as? Int64 else { return false }
        return size == translateModel.sizeBytes
    }

    /// The bundled translate engine binary (DNA3.0-4B Metal, ~1.1 MB, self-contained
    /// — embedded metallib). Copied into Contents/MacOS/translate-engine at build
    /// time (make_app.sh 2c). nil if this build didn't bundle it.
    static var translateEngineURL: URL? {
        let u = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/translate-engine")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }
    /// Translation is available only when BOTH the engine (bundled) and the model
    /// (downloaded) are present.
    static var translateAvailable: Bool { translateEngineURL != nil && translateModelIsValid() }

    /// App Support root: ~/Library/Application Support/Sovereign/
    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Sovereign", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A model bundled INSIDE the .app (self-contained DMG build) takes
    /// precedence: the engine reads it straight from the read-only, code-signed
    /// bundle — no download, no copy, works fully offline on first launch.
    /// nil for the hosted-download product build (Resources has no model).
    static var bundledModelURL: URL? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let u = res.appendingPathComponent(model.name)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// Where the engine loads the model from: the bundled copy if present
    /// (self-contained build), else App Support (download / dev-seed build).
    static var modelURL: URL { bundledModelURL ?? supportDir.appendingPathComponent(model.name) }
    static var downloadedModelURL: URL { supportDir.appendingPathComponent(model.name) }

    /// Bundled small assets dir (engine cwd for relative loads).
    static var bundledAssetsDir: URL {
        Bundle.main.resourceURL!.appendingPathComponent("assets-small", isDirectory: true)
    }
    static var bundledBPE: URL { bundledAssetsDir.appendingPathComponent("WHISPER_BPE.bin") }

    /// FAST launch gate: exists + exact size only (symlinks resolved for the
    /// SEED_MODEL=1 dev path). The integrity guarantee comes from elsewhere — the
    /// bundled copy is sealed by the app's code signature, and the downloaded copy
    /// is full-SHA-256 verified at install time (`modelFileIsValid` on the staging
    /// file, in ModelDownloader). Hashing the 867 MB model at EVERY launch would
    /// cost seconds, so it is deliberately avoided here.
    static func modelIsValid() -> Bool {
        let resolved = modelURL.resolvingSymlinksInPath()
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: resolved.path),
              let size = attrs[.size] as? Int64 else { return false }
        return size == model.sizeBytes
    }

    /// Full integrity check — call after a download completes.
    static func modelHashMatches(at url: URL = modelURL) -> Bool {
        guard let digest = try? sha256(of: url) else { return false }
        return digest == model.sha256
    }

    static func modelFileIsValid(at url: URL, expectedSize: Int64, expectedSHA256: String) -> Bool {
        // Release builds should not trust symlinked model paths: the target can
        // be swapped without changing the link entry the app originally checked.
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil else {
            return false
        }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64,
              size == expectedSize,
              let digest = try? sha256(of: url) else {
            return false
        }
        return digest == expectedSHA256
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
