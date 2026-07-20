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
                "AppInfo/AppVersion.swift",
                "Model/AssetManifest.swift",
                "Transcript/SpeakerID.swift",
                "Transcript/TranscriptStore.swift",
                "Transcript/Exporters.swift",
                "Transcript/WordMerger.swift",
                "Transcript/EditorCuts.swift",
                "Transcript/Retrieval.swift",
                "Transcript/SummaryDeck.swift",
                "Transcript/TranscriptArchive.swift",
                "Transcript/EnergyArc.swift",
                "Transcript/MeetingMode.swift",
                "Transcript/LiveCoach.swift",
                "Transcript/TitleGenerator.swift",
                "Transcript/WorkspaceRetrieval.swift",
                "Transcript/PeopleAnalytics.swift",
                "Transcript/WorkspaceAnalytics.swift",
                "Transcript/TranscriptFind.swift",
                "Transcript/PendingEnrollmentStore.swift",
                "Transcript/VoiceprintStore.swift",
                "Transcript/LiveActionRail.swift",
                "Transcript/OpenLoopsAggregator.swift",
                "Transcript/GlossaryStore.swift",
                "Transcript/PersonalVocabulary.swift",
                "Transcript/InterimTranslationCache.swift",
                "Transcript/TranscriptReconciler.swift",
                "Transcript/FAQTranslationStore.swift",
                "Transcript/GistExtractor.swift",
                "Transcript/MeetingPrepBrief.swift",
                "Transcript/PrepBriefData.swift",
                "Transcript/ReviewController.swift",
                "Engine/EngineProtocol.swift",
                "Engine/EngineEvents.swift",
                "UI/L10n.swift",
                "UI/L10nJa.swift",
                "UI/ClinicDisplaySupport.swift",
                "Audio/WavWriter.swift",
                "Audio/Segmenter.swift",
                "Engine/TranslateStreamParser.swift",
                "Dictation/DictationFormatting.swift",
            ]
        ),
        .testTarget(
            name: "SovereignCoreTests",
            dependencies: ["SovereignCore"],
            path: "Tests/SovereignCoreTests"
        ),
    ]
)
