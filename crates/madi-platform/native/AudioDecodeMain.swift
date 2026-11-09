// Small OS bridge around the shipping AVFoundation decode/resample path. Rust
// explicitly supplies the scratch directory and owns cleanup after process exit.
import Foundation

@main enum AudioDecodeMain {
    static func emit(_ value: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        data.append(10)
        try FileHandle.standardOutput.write(contentsOf: data)
    }
    static func main() async {
        guard CommandLine.arguments.count == 3 else { exit(2) }
        do {
            let source = URL(fileURLWithPath: CommandLine.arguments[1])
            let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            let result = try await AudioDecode.toWav16k(source, temporaryDirectory: directory)
            try emit(["status": "ok", "path": result.path])
        } catch {
            let native = error as NSError
            try? emit(["status": "error", "domain": native.domain, "code": native.code,
                       "reason": AudioDecode.reason(error) as Any? ?? NSNull(),
                       "message": native.localizedDescription])
            exit(1)
        }
    }
}
