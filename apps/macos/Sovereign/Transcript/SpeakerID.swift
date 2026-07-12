// SpeakerID.swift — the reserved "Unknown" speaker id and its display helper.
//
// In 화자 N명 고정 (fixed-K) mode the engine routes acoustically-distant windows
// that match none of the N fixed speakers to a single Unknown bucket, emitted as
// the reserved speaker id 255 (transcribe.zig DIAR_UNK_ID — kept verbatim in
// sync). The app renders that id as "미확인" everywhere and NEVER treats it as a
// nameable/enrollable person: it stays out of speakerNames, out of the LLM
// reconciler's speaker set, and its rename/enroll affordances are disabled.

import Foundation

enum SpeakerID {
    /// Reserved id for the single Unknown (미확인) bucket. Must match
    /// transcribe.zig `DIAR_UNK_ID` (255): positive (file mode uses spk<0 for
    /// non-speech), ≥16 (clears the engine OSD `g<16` guards), ≤255 (fits the
    /// live_ids u8 clamp).
    static let unknown = 255

    /// Human label for a speaker id. "미확인" for the Unknown bucket, else the
    /// enrolled/user name, else `fallback()` (each call site keeps its own
    /// numbering convention — "Speaker N", "화자 N", 0/1-indexed).
    static func display(_ id: Int, names: [Int: String], fallback: @autoclosure () -> String) -> String {
        if id == unknown { return "미확인" }
        return names[id] ?? fallback()
    }

    /// The label used in exports and as the round-trip token for the Unknown
    /// bucket. TranscriptArchive maps this token back to `unknown` on re-import.
    static let unknownLabel = "미확인"
}
