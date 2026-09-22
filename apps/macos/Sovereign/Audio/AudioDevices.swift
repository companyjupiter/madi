// AudioDevices.swift — enumerate Core Audio input devices and bind a chosen one
// to an AVAudioEngine. AVAudioEngine.inputNode otherwise follows the SYSTEM
// default input; this lets the app pick a specific mic (e.g. an external one)
// without the user changing System Settings.

import CoreAudio
import AVFoundation

struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
}

enum AudioDevices {
    /// All devices that expose input channels, with display names.
    static func inputs() -> [AudioInputDevice] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }

        var out: [AudioInputDevice] = []
        for id in ids where inputChannelCount(id) > 0 {
            let n = name(of: id) ?? "Device \(id)"
            // Skip the system's internal aggregates (e.g. Continuity's
            // "CADefaultDeviceAggregate-…") — not real user-facing mics.
            if n.hasPrefix("CADefaultDeviceAggregate") { continue }
            out.append(AudioInputDevice(id: id, name: n))
        }
        return out
    }

    /// The current system default input device id (nil if unavailable).
    static var defaultInputID: AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dev: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &dev) == noErr else { return nil }
        return dev
    }

    /// Bind a specific input device to the engine. Call BEFORE engine.start()
    /// (the input format is read after this) — the AUHAL takes the device id.
    static func setInput(_ id: AudioDeviceID, on engine: AVAudioEngine) {
        guard let unit = engine.inputNode.audioUnit else { return }
        var dev = id
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                             kAudioUnitScope_Global, 0, &dev,
                             UInt32(MemoryLayout<AudioDeviceID>.size))
    }

    // MARK: private

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func name(of id: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        // Core Audio returns an unretained CFString object pointer. Represent it
        // as Unmanaged so Swift does not form a raw pointer to a reference-storing
        // variable (which is undefined under the ownership model).
        var unmanaged: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &unmanaged) == noErr,
              let value = unmanaged?.takeUnretainedValue() else { return nil }
        return value as String
    }
}
