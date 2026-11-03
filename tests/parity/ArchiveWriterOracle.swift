import Foundation
struct Step: Decodable { let op: String; let folder: String?; let base: String?; let text: String? }
struct Case: Decodable { let steps: [Step] }
@main enum ArchiveWriterOracle {
    @MainActor static func main() throws {
        let cases = try JSONDecoder().decode([Case].self, from: FileHandle.standardInput.readDataToEndOfFile())
        let fm = FileManager.default
        var results: [[[String: Any]]] = []
        for c in cases {
            let root = fm.temporaryDirectory.appendingPathComponent("madi-archive-oracle-\(UUID())")
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: root) }
            let writer = SessionArchiveWriter()
            var states: [[String: Any]] = []
            for step in c.steps {
                let folder = (step.folder ?? "").isEmpty ? root : root.appendingPathComponent(step.folder!)
                let base = step.base ?? "meeting", text = step.text ?? ""
                let success: Bool
                switch step.op {
                case "save": success = writer.saveTranscript(text, folder: folder, base: base)
                case "summary": success = writer.saveSummary(text)
                case "rename": success = writer.rename(to: base, folder: folder)
                case "reset": writer.reset(); success = true
                case "file":
                    try fm.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try text.write(to: folder, atomically: true, encoding: .utf8); success = true
                case "mkdir": try fm.createDirectory(at: folder, withIntermediateDirectories: true); success = true
                case "remove": try fm.removeItem(at: folder); success = true
                default: preconditionFailure("unknown writer operation")
                }
                var files: [String: String] = [:]
                for case let path as String in fm.enumerator(atPath: root.path)! {
                    let url = root.appendingPathComponent(path)
                    let values = try url.resourceValues(forKeys: [.isDirectoryKey])
                    files[path] = values.isDirectory == true ? "directory" : try Data(contentsOf: url).map { String(format: "%02x", $0) }.joined()
                }
                let pointer = writer.transcriptURL.map { String($0.path.dropFirst(root.path.count + 1)) }
                states.append(["success": success, "error": writer.lastError != nil, "pointer": pointer as Any? ?? NSNull(), "files": files])
            }
            results.append(states)
        }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys]))
    }
}
