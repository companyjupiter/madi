// UpdateChecker.swift — "Install Update" backing logic. Reads the release for
// the running build's channel from Madi's CloudFront feed, downloads the DMG to
// private staging, verifies its exact byte count + SHA-256, and only then opens
// it so Finder can mount the drag-to-Applications volume.

import Foundation
import AppKit
import Observation

private struct UpdateDownloadContext: Codable, Sendable {
    let expectedURL: URL
    let stagingURL: URL
    let finalURL: URL
    let expectedSize: Int64
    let expectedSHA256: String
}

private func decodeDownloadContext(_ description: String?) -> UpdateDownloadContext? {
    guard let description, let data = description.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(UpdateDownloadContext.self, from: data)
}

private func responseURLMatches(_ actual: URL, expected: URL) -> Bool {
    actual.scheme?.lowercased() == "https"
        && actual.host?.lowercased() == "madi.devart.tv"
        && (actual.port ?? 443) == (expected.port ?? 443)
        && actual.path == expected.path
        && actual.query == expected.query
}

@Observable
@MainActor
final class UpdateChecker: NSObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate                       // no release newer than current
        case available(ReleaseInfo)
        case downloading(progress: Double)  // 0…1
        case verifying
        case downloaded(URL)                // verified DMG, opened in Finder
        case failed(String)
    }

    private(set) var state: State = .idle
    /// Kept across the download so the UI can show what's being installed.
    private(set) var pending: ReleaseInfo?

    private var session: URLSession!
    private var downloadTask: URLSessionDownloadTask?

    override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    private var requestedChannel: String? {
        let value = AppVersion.channel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["stable", "beta", "rc"].contains(value) ? value : nil
    }

    private func feedRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 20
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("Madi-Updater/\(AppVersion.full)", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func downloadRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 120
        )
        request.setValue(
            "application/x-apple-diskimage, application/octet-stream",
            forHTTPHeaderField: "Accept"
        )
        request.setValue("Madi-Updater/\(AppVersion.full)", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// Query the CloudFront channel feed and decide whether a newer build exists.
    func check() {
        state = .checking
        pending = nil
        guard let channel = requestedChannel,
              let feedURL = URL(string: "https://madi.devart.tv/channels/\(channel)/latest.json") else {
            state = .failed("지원하지 않는 업데이트 채널입니다: \(AppVersion.channel)")
            return
        }

        Task {
            do {
                let (data, response) = try await session.data(for: feedRequest(feedURL))
                guard let http = response as? HTTPURLResponse else {
                    state = .failed("네트워크 응답을 받지 못했습니다.")
                    return
                }
                guard http.statusCode == 200,
                      let responseURL = http.url,
                      responseURLMatches(responseURL, expected: feedURL),
                      http.mimeType?.lowercased() == "application/json" else {
                    state = .failed("업데이트 서버 응답 오류 (HTTP \(http.statusCode)). 잠시 후 다시 시도해 주세요.")
                    return
                }
                guard data.count <= 64 * 1024 else {
                    state = .failed("업데이트 정보가 허용된 크기를 초과했습니다.")
                    return
                }
                guard let newest = try ReleaseFeed.newest(
                    from: data,
                    current: AppVersion.current,
                    channel: channel
                ) else {
                    state = .upToDate
                    return
                }
                pending = newest
                state = .available(newest)
            } catch is ReleaseFeedError {
                state = .failed("업데이트 정보 형식이 올바르지 않습니다.")
            } catch {
                state = .failed("업데이트 확인 실패: \(error.localizedDescription)")
            }
        }
    }

    /// Download the pending release's DMG and open it after integrity validation.
    func installPending() {
        guard let release = pending else { return }
        let dmgURL = release.dmgURL

        do {
            let updatesDirectory = AssetManifest.supportDir
                .appendingPathComponent("Updates", isDirectory: true)
            try FileManager.default.createDirectory(
                at: updatesDirectory,
                withIntermediateDirectories: true
            )
            let context = UpdateDownloadContext(
                expectedURL: dmgURL,
                stagingURL: updatesDirectory
                    .appendingPathComponent(".\(UUID().uuidString).download"),
                finalURL: updatesDirectory.appendingPathComponent(dmgURL.lastPathComponent),
                expectedSize: release.dmgSize,
                expectedSHA256: release.sha256
            )
            let encoded = try JSONEncoder().encode(context)
            guard let description = String(data: encoded, encoding: .utf8) else {
                throw CocoaError(.fileWriteUnknown)
            }

            state = .downloading(progress: 0)
            let task = session.downloadTask(with: downloadRequest(dmgURL))
            task.taskDescription = description
            downloadTask = task
            task.resume()
        } catch {
            state = .failed("다운로드 준비 실패: \(error.localizedDescription)")
        }
    }

    func openReleasesPage() {
        NSWorkspace.shared.open(AppVersion.releasesURL)
    }
}

extension UpdateChecker: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession,
                               downloadTask: URLSessionDownloadTask,
                               didWriteData _: Int64,
                               totalBytesWritten written: Int64,
                               totalBytesExpectedToWrite expected: Int64) {
        let fallback = decodeDownloadContext(downloadTask.taskDescription)?.expectedSize ?? 0
        let total = expected > 0 ? expected : fallback
        let progress = total > 0 ? min(1, Double(written) / Double(total)) : 0
        Task { @MainActor in self.state = .downloading(progress: progress) }
    }

    nonisolated func urlSession(_ session: URLSession,
                               downloadTask: URLSessionDownloadTask,
                               didFinishDownloadingTo location: URL) {
        let taskIdentifier = downloadTask.taskIdentifier
        guard let context = decodeDownloadContext(downloadTask.taskDescription),
              let http = downloadTask.response as? HTTPURLResponse,
              http.statusCode == 200,
              let responseURL = http.url,
              responseURLMatches(responseURL, expected: context.expectedURL),
              http.expectedContentLength <= 0 || http.expectedContentLength == context.expectedSize else {
            Task { @MainActor in
                guard self.downloadTask?.taskIdentifier == taskIdentifier else { return }
                self.downloadTask = nil
                self.state = .failed("다운로드 서버의 응답을 신뢰할 수 없습니다.")
            }
            return
        }

        // URLSession removes `location` when this callback returns, so preserve
        // it synchronously under the app's private updates directory first.
        do {
            guard !FileManager.default.fileExists(atPath: context.stagingURL.path) else {
                throw CocoaError(.fileWriteFileExists)
            }
            try FileManager.default.moveItem(at: location, to: context.stagingURL)
        } catch {
            Task { @MainActor in
                guard self.downloadTask?.taskIdentifier == taskIdentifier else { return }
                self.downloadTask = nil
                self.state = .failed("저장 실패: \(error.localizedDescription)")
            }
            return
        }

        Task { @MainActor in
            self.state = .verifying
            let isValid = await Task.detached(priority: .utility) {
                AssetManifest.fileIsValid(
                    at: context.stagingURL,
                    expectedSize: context.expectedSize,
                    expectedSHA256: context.expectedSHA256
                )
            }.value
            guard isValid else {
                try? FileManager.default.removeItem(at: context.stagingURL)
                self.downloadTask = nil
                self.state = .failed("다운로드한 DMG의 크기 또는 SHA-256이 일치하지 않습니다.")
                return
            }

            do {
                try? FileManager.default.removeItem(at: context.finalURL)
                try FileManager.default.moveItem(at: context.stagingURL, to: context.finalURL)
            } catch {
                try? FileManager.default.removeItem(at: context.stagingURL)
                self.downloadTask = nil
                self.state = .failed("설치 파일 저장 실패: \(error.localizedDescription)")
                return
            }

            self.downloadTask = nil
            guard NSWorkspace.shared.open(context.finalURL) else {
                self.state = .failed("검증된 DMG를 Finder에서 열 수 없습니다.")
                return
            }
            self.state = .downloaded(context.finalURL)
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                               task: URLSessionTask,
                               didCompleteWithError error: Error?) {
        guard let error else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        let taskIdentifier = task.taskIdentifier
        Task { @MainActor in
            guard self.downloadTask?.taskIdentifier == taskIdentifier else { return }
            if case .downloaded = self.state { return }
            self.downloadTask = nil
            self.state = .failed(error.localizedDescription)
        }
    }
}
