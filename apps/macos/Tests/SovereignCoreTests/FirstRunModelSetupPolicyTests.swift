import XCTest
@testable import SovereignCore

final class FirstRunModelSetupPolicyTests: XCTestCase {
    func testMissingWhisperAlwaysBlocksLaunch() {
        for choice in [FirstRunModelSetupChoice?.none, .transcriptionOnly, .recommended] {
            XCTAssertFalse(FirstRunModelSetupPolicy.canEnterApp(
                requiredModelReady: false,
                translationModelReady: true,
                translationEngineAvailable: true,
                choice: choice))
        }
    }

    func testExistingInstallEntersWithoutFirstRunChoice() {
        XCTAssertTrue(FirstRunModelSetupPolicy.canEnterApp(
            requiredModelReady: true,
            translationModelReady: false,
            translationEngineAvailable: true,
            choice: nil))
    }

    func testRecommendedSetupWaitsForDNA() {
        XCTAssertFalse(FirstRunModelSetupPolicy.canEnterApp(
            requiredModelReady: true,
            translationModelReady: false,
            translationEngineAvailable: true,
            choice: .recommended))
        XCTAssertTrue(FirstRunModelSetupPolicy.canEnterApp(
            requiredModelReady: true,
            translationModelReady: true,
            translationEngineAvailable: true,
            choice: .recommended))
    }

    func testTranscriptionOnlyEntersAsSoonAsWhisperIsReady() {
        XCTAssertTrue(FirstRunModelSetupPolicy.canEnterApp(
            requiredModelReady: true,
            translationModelReady: false,
            translationEngineAvailable: true,
            choice: .transcriptionOnly))
    }

    func testDownloadTotalsExcludeAlreadyInstalledAssets() {
        let dnaBytes: Int64 = 1_234
        XCTAssertEqual(FirstRunModelSetupPolicy.downloadBytes(
            choice: .recommended,
            requiredModelReady: false,
            translationModelReady: false,
            translationAssetBytes: dnaBytes), AssetManifest.model.sizeBytes + dnaBytes)
        XCTAssertEqual(FirstRunModelSetupPolicy.downloadBytes(
            choice: .recommended,
            requiredModelReady: true,
            translationModelReady: false,
            translationAssetBytes: dnaBytes), dnaBytes)
        XCTAssertEqual(FirstRunModelSetupPolicy.downloadBytes(
            choice: .transcriptionOnly,
            requiredModelReady: false,
            translationModelReady: false,
            translationAssetBytes: dnaBytes), AssetManifest.model.sizeBytes)
    }
}
