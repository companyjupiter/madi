// Main-thread ownership adapter around the unchanged shipping LinePlayer.
import Foundation
import Observation

typealias PlaybackChanged = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int) -> Void

@MainActor
private final class PlaybackEndpoint {
    let player = LinePlayer()
    let context: UnsafeMutableRawPointer?
    let changed: PlaybackChanged
    var active = true
    var published = false
    var lastPublished: UUID?

    init(context: UnsafeMutableRawPointer?, changed: @escaping PlaybackChanged) {
        self.context = context
        self.changed = changed
        observe()
    }
    func publish() {
        guard active else { return }
        let current = player.currentLine
        guard !published || current != lastPublished else { return }
        published = true
        lastPublished = current
        let bytes = Array((current?.uuidString ?? "").utf8)
        bytes.withUnsafeBufferPointer { changed(context, $0.baseAddress, $0.count) }
    }
    func observe() {
        guard active else { return }
        withObservationTracking {
            _ = player.currentLine
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.active else { return }
                self.observe()
                self.publish()
            }
        }
        publish()
    }
    func close() {
        player.stop()
        publish()
        active = false
    }
}

@_cdecl("madi_playback_create")
func playbackCreate(_ context: UnsafeMutableRawPointer?, _ changed: @escaping PlaybackChanged) -> UnsafeMutableRawPointer? {
    guard Thread.isMainThread else { return nil }
    return MainActor.assumeIsolated {
        Unmanaged.passRetained(PlaybackEndpoint(context: context, changed: changed)).toOpaque()
    }
}

@_cdecl("madi_playback_toggle")
func playbackToggle(_ handle: UnsafeMutableRawPointer, _ path: UnsafePointer<UInt8>, _ pathCount: Int,
                    _ line: UnsafePointer<UInt8>, _ lineCount: Int, _ from: Double, _ to: Double) -> Int32 {
    guard Thread.isMainThread, pathCount > 0, lineCount > 0, from.isFinite, to.isFinite else { return 0 }
    guard let path = String(bytes: UnsafeBufferPointer(start: path, count: pathCount), encoding: .utf8),
          let idText = String(bytes: UnsafeBufferPointer(start: line, count: lineCount), encoding: .utf8),
          let id = UUID(uuidString: idText) else { return 0 }
    return MainActor.assumeIsolated {
        let owner = Unmanaged<PlaybackEndpoint>.fromOpaque(handle).takeUnretainedValue()
        guard owner.active else { return 0 }
        owner.player.toggle(url: URL(fileURLWithPath: path), line: id, from: from, to: to)
        owner.publish()
        return 1
    }
}

@_cdecl("madi_playback_stop")
func playbackStop(_ handle: UnsafeMutableRawPointer) {
    guard Thread.isMainThread else { return }
    MainActor.assumeIsolated {
        let owner = Unmanaged<PlaybackEndpoint>.fromOpaque(handle).takeUnretainedValue()
        owner.player.stop()
        owner.publish()
    }
}

@_cdecl("madi_playback_destroy")
func playbackDestroy(_ handle: UnsafeMutableRawPointer) {
    guard Thread.isMainThread else { return }
    MainActor.assumeIsolated {
        let owner = Unmanaged<PlaybackEndpoint>.fromOpaque(handle).takeRetainedValue()
        owner.close()
    }
}
