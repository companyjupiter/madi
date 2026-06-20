// swift-tools-version:5.9
// Headless test package for the app's PURE-LOGIC core (no SwiftUI/AppKit) so it
// runs via `swift test` with zero GUI — the make_app.sh swiftc build is untouched
// (it uses its own explicit SRCS list, not this manifest). Only the Foundation-
// only files are pulled into SovereignCore; views/engine-IO stay out.
//
//   cd app && swift test            # runs the unit tests headless
//
// quark v9 (configs/sovereign_whisper_app.mjs) reads Tests/ to mark modules
// tested (wired → tested).
import PackageDescription

let package = Package(
    name: "SovereignCore",
    platforms: [.macOS(.v14)],   // @Observable (TranscriptStore) needs macOS 14+
    targets: [
        .target(
            name: "SovereignCore",
            path: "Sovereign",
            sources: [
                "Transcript/TranscriptStore.swift",
                "Transcript/WordMerger.swift",
                "Transcript/EditorCuts.swift",
                "Transcript/Retrieval.swift",
                "Transcript/SummaryDeck.swift",
                "Engine/EngineProtocol.swift",
            ]
        ),
        .testTarget(
            name: "SovereignCoreTests",
            dependencies: ["SovereignCore"],
            path: "Tests/SovereignCoreTests"
        ),
    ]
)
