import Foundation
import XCTest
@testable import SovereignCore

final class DownloadedReleaseValidationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("madi-release-integrity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testAcceptsExactSizeAndSHA256() throws {
        let file = directory.appendingPathComponent("madi.dmg")
        try Data("trusted release bytes".utf8).write(to: file)
        let digest = try AssetManifest.sha256(of: file)

        XCTAssertTrue(AssetManifest.fileIsValid(
            at: file,
            expectedSize: 21,
            expectedSHA256: digest
        ))
    }

    func testRejectsWrongSize() throws {
        let file = directory.appendingPathComponent("madi.dmg")
        try Data("trusted release bytes".utf8).write(to: file)
        let digest = try AssetManifest.sha256(of: file)

        XCTAssertFalse(AssetManifest.fileIsValid(
            at: file,
            expectedSize: 22,
            expectedSHA256: digest
        ))
    }

    func testRejectsSameSizeWrongBytes() throws {
        let trusted = directory.appendingPathComponent("trusted.dmg")
        let tampered = directory.appendingPathComponent("tampered.dmg")
        try Data("trusted release bytes".utf8).write(to: trusted)
        try Data("tampered releas bytes".utf8).write(to: tampered)
        let digest = try AssetManifest.sha256(of: trusted)

        XCTAssertFalse(AssetManifest.fileIsValid(
            at: tampered,
            expectedSize: 21,
            expectedSHA256: digest
        ))
    }

    func testRejectsSymlink() throws {
        let target = directory.appendingPathComponent("target.dmg")
        let link = directory.appendingPathComponent("link.dmg")
        try Data("trusted release bytes".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let digest = try AssetManifest.sha256(of: target)

        XCTAssertFalse(AssetManifest.fileIsValid(
            at: link,
            expectedSize: 21,
            expectedSHA256: digest
        ))
    }
}
