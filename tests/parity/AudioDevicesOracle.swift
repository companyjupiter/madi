// Calls the unmodified native enumeration, without opening an audio stream.
import Foundation

@main
struct AudioDevicesOracle {
    static func main() throws {
        let devices = AudioDevices.inputs().map { ["id": "coreaudio:\($0.id)", "name": $0.name] }
        let result: [String: Any] = [
            "supported": true,
            "devices": devices,
            "defaultInputId": AudioDevices.defaultInputID.map { "coreaudio:\($0)" } as Any? ?? NSNull(),
        ]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]))
    }
}
