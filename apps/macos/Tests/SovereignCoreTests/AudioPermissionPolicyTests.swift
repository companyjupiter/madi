import XCTest
@testable import SovereignCore

final class AudioPermissionPolicyTests: XCTestCase {
    func testMicrophoneRequiresOnlyMicrophonePermission() {
        XCTAssertEqual(AudioPermissionPolicy.required(for: .mic), [.microphone])
    }

    func testSystemAudioDoesNotRequireMicrophonePermission() {
        XCTAssertEqual(AudioPermissionPolicy.required(for: .system), [.systemAudio])
        XCTAssertFalse(AudioPermissionPolicy.requires(.microphone, for: .system))
    }

    func testMixedCaptureRequiresBothPermissionsBeforeCountdown() {
        XCTAssertEqual(AudioPermissionPolicy.required(for: .both), [.microphone, .systemAudio])
    }
}
