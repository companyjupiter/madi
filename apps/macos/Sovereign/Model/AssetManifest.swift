// AssetManifest.swift — what the app downloads on first run and where it lives.
//
// Small assets (pyannote/silero/resnet/bpe/mel/conv/pos_emb/tokenizer) ship
// INSIDE the bundle (Resources/assets-small). Only the ~830 MB Q8 model.safetensors
// is fetched on first run into Application Support, verified by SHA-256.
// (Q8 is 1.86x smaller than F16 — the old "1.5 GB" figure was the F16 model.)
//
// Hosting: both models are hosted on Hugging Face with pinned `resolve/main`
// endpoints and their real SHA-256/size below (verified == local 2026-06-22).
// Bumping a model = new HF upload + a new app build with updated hash/size here.

import Foundation
import CryptoKit

struct RemoteAsset {
    let name: String
    let url: URL
    let sha256: String        // lowercase hex of the expected digest
    let sizeBytes: Int64
    /// Approx extra RAM the model needs at runtime, in GB (nil = negligible).
    /// Documented here so the requirement lives with the asset, not only in UI copy.
    var approxRuntimeMemoryGB: Double? = nil
}

enum TranslateModelVariant: String, CaseIterable {
    case quality4B
    case realtime2B

    var displayName: String {
        switch self {
        case .quality4B: return "DNA3.0-4B"
        case .realtime2B: return "DNA3.0-2B"
        }
    }

    var engineExecutableName: String {
        switch self {
        case .quality4B: return "translate-engine-4b"
        case .realtime2B: return "translate-engine-2b"
        }
    }
}

enum AssetManifest {
    /// The large model fetched on first run — the pre-quantized Q8 build
    /// (bench/quantize_q8.py output), 1.86x smaller than F16 with proven zero
    /// quality change (engine loads its Q8 directly; WHASH weight-identity).
    /// sha256/size = the shipping Q8 safetensors (verified == local 2026-06-22).
    /// Hosted on Hugging Face (jupitersong), `resolve/main` = stable direct
    /// download (302 → HF CDN; URLSession follows redirects), mirroring the
    /// translate model. Bumping the model = new HF upload + new app build with
    /// updated sha256/size below.
    static let model = RemoteAsset(
        name: "model.q8.safetensors",
        url: URL(string: "https://huggingface.co/jupitersong/madi-whisper-turbo-v3-q8/resolve/main/model.q8.safetensors")!,
        sha256: "1014fd3ad4450a2e43e473eebbab485b165fd68cbe932372071d86c522bb5c8e",
        sizeBytes: 867_485_320
    )

    /// Live-translation model — DNA3.0-4B (Qwen3.5 base + Korean tuning), Q4_K_M
    /// GGUF (~2.6 GB). DELIBERATELY NOT bundled in the app/DMG: it would ~quadruple
    /// the download, and translation is opt-in. Fetched on demand into App Support
    /// via a button (TranslateModelDownloader) the first time the user enables it.
    /// Hosted on Hugging Face (mradermacher's i1/imatrix GGUF quant of dnotitia/DNA3.0-4B).
    /// `resolve/main` is the stable direct-download endpoint (302 → HF xet CDN). Verified
    /// against this exact file: x-linked-size 2,783,447,424 + sha256 a00a837a… == local.
    static let translateModel4B = RemoteAsset(
        name: "DNA3.0-4B.i1-Q4_K_M.gguf",
        url: URL(string: "https://huggingface.co/mradermacher/DNA3.0-4B-i1-GGUF/resolve/main/DNA3.0-4B.i1-Q4_K_M.gguf")!,
        sha256: "a00a837a797d95b23c31e2821855e89d6b931b9c80c59d7dd5dd219554590fd8",
        sizeBytes: 2_783_447_424,
        // 3.2 GB measured against the current engine (3.35 before per-layer Q6_K packing,
        // 5.1 on 0.1.4). Two engine changes got it here: dropping the second copy of every
        // Q4_K weight, then storing V/W2 Q6_K as 6.5-bit ql/qh with no raw blocks — see
        // sovereignLLM apps/metal-dna3-4b-q4km/PERF_MATRIX.md sections 3 and 12.
        // This is phys_footprint, which is what the tier rule below reasons about; RSS is
        // higher (5.2 GB) because the GGUF mapping is resident but evictable and is charged
        // to RSS only. Shown to the user in SettingsView / ModelGateView, so keep it honest.
        approxRuntimeMemoryGB: 3.2
    )

    /// Low-memory live-translation model for 8 GB Macs. Same qwen35 hybrid
    /// architecture/tokenizer as 4B, model-specific Metal binary, Q4_K_M.
    /// 1.54 GB phys_footprint against the current engine vs 3.2 GB for the 4B (-52%).
    /// (0.1.5 shipped at 1.61; 0.1.4 was 2,405 MB vs 5,119 MB.)
    static let translateModel2B = RemoteAsset(
        name: "DNA3.0-2B.i1-Q4_K_M.gguf",
        url: URL(string: "https://huggingface.co/mradermacher/DNA3.0-2B-i1-GGUF/resolve/main/DNA3.0-2B.i1-Q4_K_M.gguf")!,
        sha256: "9270db053b27f1ec127e37ad7aaec0efa05dc89fbd158f3c4724e33e478da7a3",
        sizeBytes: 1_312_165_344,
        // 1.5 GB. Kept as-is rather than raised: the packing moved the true figure
        // 1.61 -> 1.54, so this rounded constant is now honest where it was slightly
        // optimistic before. Do not lower it further without a fresh measurement.
        approxRuntimeMemoryGB: 1.5
    )

    /// 8 GB is the only current Mac capacity below 12 GiB, so the midpoint
    /// threshold is robust to future reporting/rounding while leaving 16 GB+
    /// on the quality-default 4B profile.
    ///
    /// Re-confirmed against the 0.1.5 footprints rather than carried over: the 4B fell
    /// 5.1 -> 3.3 GB, which is what made the threshold worth re-examining at all. A live
    /// session is translation + transcription (1.05-1.26 GB) + the app, so 4B now costs
    /// ~4.6 GB against ~6.8 GB before. That is comfortable at 16 GB and still the wrong
    /// bet at 8 GB, where 4.6 GB of a machine that also runs the OS and the user's other
    /// apps leaves no margin and there is no memory-pressure handling anywhere in the app
    /// to fall back on. 12 GiB stays the boundary; the 4B just has much more room above it.
    static let translateTierThresholdBytes: UInt64 = 12 * (1 << 30)
    static func recommendedTranslateModelVariant(physicalMemory: UInt64) -> TranslateModelVariant {
        physicalMemory < translateTierThresholdBytes ? .realtime2B : .quality4B
    }

    static var translateModelVariant: TranslateModelVariant {
        if let forced = ProcessInfo.processInfo.environment["MADI_TRANSLATE_MODEL"]?.lowercased() {
            if forced == "2b" { return .realtime2B }
            if forced == "4b" { return .quality4B }
        }
        return recommendedTranslateModelVariant(physicalMemory: ProcessInfo.processInfo.physicalMemory)
    }

    static func translateModel(for variant: TranslateModelVariant) -> RemoteAsset {
        variant == .realtime2B ? translateModel2B : translateModel4B
    }

    static var translateModel: RemoteAsset { translateModel(for: translateModelVariant) }

    /// Always App Support (never bundled). The small engine binaries ARE bundled.
    static func translateModelURL(for variant: TranslateModelVariant) -> URL {
        supportDir.appendingPathComponent(translateModel(for: variant).name)
    }
    static var translateModelURL: URL { translateModelURL(for: translateModelVariant) }
    /// Fast presence gate (size-only, symlinks resolved for the dev-seed path —
    /// like the main model launch gate).
    static func translateModelIsValid(_ variant: TranslateModelVariant = translateModelVariant) -> Bool {
        let asset = translateModel(for: variant)
        let resolved = translateModelURL(for: variant).resolvingSymlinksInPath()
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: resolved.path),
              let size = attrs[.size] as? Int64 else { return false }
        return size == asset.sizeBytes
    }

    /// Selected bundled Metal binary (one binary per model+quant, embedded
    /// metallib). Both are copied into Contents/MacOS by make_app.sh.
    static var translateEngineURL: URL? {
        let name = translateModelVariant.engineExecutableName
        let u = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/\(name)")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }
    /// Translation is available only when BOTH the engine (bundled) and the model
    /// (downloaded) are present.
    static var translateAvailable: Bool { translateEngineURL != nil && translateModelIsValid() }

    /// App Support root: ~/Library/Application Support/Madi/
    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Madi", isDirectory: true)
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

    /// Full byte-integrity check shared by model and release downloads.
    static func fileIsValid(at url: URL, expectedSize: Int64, expectedSHA256: String) -> Bool {
        // Release builds should not trust symlinked download paths: the target can
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

    /// Compatibility name retained for the existing model downloaders.
    static func modelFileIsValid(at url: URL, expectedSize: Int64, expectedSHA256: String) -> Bool {
        fileIsValid(at: url, expectedSize: expectedSize, expectedSHA256: expectedSHA256)
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
