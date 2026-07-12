// UpdateChecker.swift — "Install Update" backing logic. Queries the GitHub
// Releases API for companyjupiter/madi, picks the newest release by SemVer
// precedence (prereleases INCLUDED — this is a beta channel; a stable Official
// release outranks any beta by the same comparator), and, when newer than the
// running build, downloads its `.dmg` asset and opens it (Finder mounts it and
// shows the drag-to-Applications window). No Sparkle: the app is a swiftc-
// assembled, Developer-ID-signed, DMG-distributed bundle, so "install" = fetch
// the notarized DMG and hand it to Finder.
//
// GitHub's `/releases/latest` deliberately EXCLUDES prereleases, so we list
// `/releases` and choose the max SemVer ourselves. Public repo → unauthenticated
// (60 req/hr, ample for a manual menu action). A User-Agent header is required by
// the API or it 403s.

import Foundation
import AppKit
import Observation

@Observable
@MainActor
final class UpdateChecker: NSObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate                       // no release newer than current
        case available(ReleaseInfo)
        case downloading(progress: Double)  // 0…1
        case downloaded(URL)                // DMG on disk, opened in Finder
        case failed(String)
    }

    private(set) var state: State = .idle
    /// Kept across the download so the UI can show what's being installed.
    private(set) var pending: ReleaseInfo?

    private var session: URLSession!
    private var downloadTask: URLSessionDownloadTask?
    /// Destination for the in-flight DMG, computed on the main actor in
    /// `installPending` BEFORE the download starts, then read once in the
    /// (background) completion delegate — where the temp file must be moved
    /// synchronously before it's reaped. Written-once/read-once → no real race.
    @ObservationIgnored private nonisolated(unsafe) var stagedDMGDest: URL?

    override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    private var releasesAPI: URL {
        URL(string: "https://api.github.com/repos/\(AppVersion.repoOwner)/\(AppVersion.repoName)/releases?per_page=30")!
    }

    private func apiRequest(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("Madi-Updater/\(AppVersion.full)", forHTTPHeaderField: "User-Agent")
        r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        r.timeoutInterval = 20
        return r
    }

    /// Query GitHub and decide whether a newer build exists.
    func check() {
        state = .checking
        pending = nil
        Task {
            do {
                let (data, resp) = try await session.data(for: apiRequest(releasesAPI))
                guard let http = resp as? HTTPURLResponse else {
                    state = .failed("네트워크 응답을 받지 못했습니다."); return
                }
                guard http.statusCode == 200 else {
                    state = .failed("GitHub 응답 오류 (HTTP \(http.statusCode)). 잠시 후 다시 시도해 주세요.")
                    return
                }
                guard let newest = ReleaseFeed.newest(from: data, current: AppVersion.current) else {
                    state = .upToDate; return
                }
                pending = newest
                state = .available(newest)
            } catch {
                state = .failed("업데이트 확인 실패: \(error.localizedDescription)")
            }
        }
    }

    /// Download the pending release's DMG and open it in Finder.
    func installPending() {
        guard let rel = pending else { return }
        guard let dmg = rel.dmgURL else {
            // No attached DMG — fall back to the release page in the browser.
            NSWorkspace.shared.open(rel.pageURL)
            state = .downloaded(rel.pageURL)
            return
        }
        let stem = "Madi-" + rel.tag.replacingOccurrences(of: "/", with: "-")
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        stagedDMGDest = downloads.appendingPathComponent(stem + ".dmg")
        state = .downloading(progress: 0)
        let t = session.downloadTask(with: apiRequest(dmg))
        downloadTask = t
        t.resume()
    }

    func openReleasesPage() {
        NSWorkspace.shared.open(AppVersion.releasesURL)
    }
}

extension UpdateChecker: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                               didWriteData _: Int64, totalBytesWritten written: Int64,
                               totalBytesExpectedToWrite expected: Int64) {
        let p = expected > 0 ? min(1, Double(written) / Double(expected)) : 0
        Task { @MainActor in self.state = .downloading(progress: p) }
    }

    nonisolated func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                               didFinishDownloadingTo location: URL) {
        // The temp file is reaped once this callback returns, so move it NOW
        // (synchronously) to the pre-computed destination in ~/Downloads, then
        // hop to the main actor to open it (Finder mounts the DMG).
        let dest = stagedDMGDest
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("Madi-update.dmg")
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            Task { @MainActor in self.state = .failed("저장 실패: \(error.localizedDescription)") }
            return
        }
        Task { @MainActor in
            NSWorkspace.shared.open(dest)
            self.state = .downloaded(dest)
        }
    }

    nonisolated func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        Task { @MainActor in
            if case .downloaded = self.state { return }
            self.state = .failed(error.localizedDescription)
        }
    }
}
