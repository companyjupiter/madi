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
        case failed(String)
    }

    private(set) var state: State = .idle

    private var session: URLSession!
    private var task: URLSessionDownloadTask?

    override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    /// Ensure the model is present and valid; download if not.
    func ensureModel() {
        state = .checking
        if AssetManifest.modelIsValid() { state = .ready; return }
        startDownload()
    }

    func startDownload() {
        state = .downloading(progress: 0)
        let t = session.downloadTask(with: AssetManifest.model.url)
        task = t
        t.resume()
    }

    func cancel() {
        task?.cancel()
        state = .idle
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
        // move first (temp file is deleted when this returns), then verify
        let dest = AssetManifest.modelURL
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            Task { @MainActor in self.state = .failed("move failed: \(error.localizedDescription)") }
            return
        }
        Task { @MainActor in
            self.state = .verifying
            // full digest check (slow, once) — launch-time uses the fast size check
            let ok = await Task.detached { AssetManifest.modelHashMatches() }.value
            self.state = ok ? .ready
                : .failed("SHA-256 mismatch — re-download")
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
