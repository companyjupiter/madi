// ModelDownloader.swift — first-run download of model.safetensors with progress
// and SHA-256 verification. Observable so a SwiftUI sheet can show progress.

import Foundation
import Observation

@Observable
@MainActor
final class ModelDownloader: NSObject {
    enum State: Equatable {
        case idle
        case checking
        case downloading(progress: Double)   // 0…1
        case verifying
        case ready
        case cancelled                       // user cancelled — recoverable via startDownload()
        case failed(String)
    }

    private(set) var state: State = .idle

    private var session: URLSession!
    private var task: URLSessionDownloadTask?

    override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        // Avoid flashing the first-run guide for an existing installation before
        // SovereignApp's .task gets its first turn on the main actor.
        if AssetManifest.modelIsValid() { state = .ready }
    }

    /// Check the launch requirement. A missing model deliberately stays idle so
    /// the first-run guide can explain the download choices before network I/O.
    func ensureModel() {
        state = .checking
        if AssetManifest.modelIsValid() { state = .ready; return }
        state = .idle
    }

    func startDownload() {
        state = .downloading(progress: 0)
        let t = session.downloadTask(with: AssetManifest.model.url)
        task = t
        t.resume()
    }

    func cancel() {
        task?.cancel()
        state = .cancelled
    }
}

extension ModelDownloader: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                               didWriteData _: Int64, totalBytesWritten written: Int64,
                               totalBytesExpectedToWrite expected: Int64) {
        let total = expected > 0 ? expected : AssetManifest.model.sizeBytes
        let p = min(1, Double(written) / Double(total))
        Task { @MainActor in self.state = .downloading(progress: p) }
    }

    nonisolated func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                               didFinishDownloadingTo location: URL) {
        let dest = AssetManifest.downloadedModelURL
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
                    expectedSize: AssetManifest.model.sizeBytes,
                    expectedSHA256: AssetManifest.model.sha256
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
                if !AssetManifest.modelIsValid() { try? FileManager.default.removeItem(at: dest) }
                self.state = .failed("SHA-256 mismatch — re-download")
            }
        }
    }

    nonisolated func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        // A user cancel() surfaces here as NSURLErrorCancelled; keep the
        // recoverable .cancelled state instead of clobbering it with .failed.
        if (error as NSError).code == NSURLErrorCancelled { return }
        Task { @MainActor in
            if case .ready = self.state { return }
            if case .cancelled = self.state { return }
            self.state = .failed(error.localizedDescription)
        }
    }
}
