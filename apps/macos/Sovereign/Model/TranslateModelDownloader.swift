// TranslateModelDownloader.swift — on-demand download of the hardware-selected
// DNA3 translate model into App Support, with progress + SHA-256 verification. The
// model is NOT bundled (keeps the base DMG light); the user fetches it with a
// button when enabling live translation.
//
// Forked from ModelDownloader (per the project's per-app-fork-over-shared-module
// philosophy) so the Whisper-model download path stays untouched. Same proven
// staging→verify→install flow.

import Foundation
import Observation

@Observable
@MainActor
final class TranslateModelDownloader: NSObject {
    enum State: Equatable {
        case idle
        case downloading(progress: Double)   // 0…1
        case verifying
        case ready
        case failed(String)
    }

    private(set) var state: State = .idle

    private var session: URLSession!
    private var task: URLSessionDownloadTask?

    override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        if AssetManifest.translateModelIsValid() { state = .ready }
    }

    /// Re-check presence (e.g. when the Settings sheet appears).
    func refresh() {
        if AssetManifest.translateModelIsValid() { state = .ready }
        else if case .downloading = state {} else { state = .idle }
    }

    func startDownload() {
        state = .downloading(progress: 0)
        let t = session.downloadTask(with: AssetManifest.translateModel.url)
        task = t
        t.resume()
    }

    func cancel() {
        task?.cancel()
        state = AssetManifest.translateModelIsValid() ? .ready : .idle
    }
}

extension TranslateModelDownloader: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                               didWriteData _: Int64, totalBytesWritten written: Int64,
                               totalBytesExpectedToWrite expected: Int64) {
        let total = expected > 0 ? expected : AssetManifest.translateModel.sizeBytes
        let p = min(1, Double(written) / Double(total))
        Task { @MainActor in self.state = .downloading(progress: p) }
    }

    nonisolated func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                               didFinishDownloadingTo location: URL) {
        let dest = AssetManifest.translateModelURL
        let staging = dest.deletingLastPathComponent()
            .appendingPathComponent(".\(dest.lastPathComponent).download")
        do {
            try? FileManager.default.removeItem(at: staging)
            try FileManager.default.moveItem(at: location, to: staging)
        } catch {
            Task { @MainActor in self.state = .failed("move failed: \(error.localizedDescription)") }
            return
        }
        Task { @MainActor in
            self.state = .verifying
            let ok = await Task.detached {
                AssetManifest.modelFileIsValid(
                    at: staging,
                    expectedSize: AssetManifest.translateModel.sizeBytes,
                    expectedSHA256: AssetManifest.translateModel.sha256
                )
            }.value
            if ok {
                do {
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.moveItem(at: staging, to: dest)
                    self.state = .ready
                } catch {
                    try? FileManager.default.removeItem(at: staging)
                    self.state = .failed("install failed: \(error.localizedDescription)")
                }
            } else {
                try? FileManager.default.removeItem(at: staging)
                self.state = .failed("SHA-256 mismatch — re-download")
            }
        }
    }

    nonisolated func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        Task { @MainActor in
            if case .ready = self.state { return }
            self.state = .failed(error.localizedDescription)
        }
    }
}
