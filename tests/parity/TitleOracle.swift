import Foundation

@main struct TitleOracle {
    static func main() throws {
        let inputs = try JSONDecoder().decode([String].self, from: FileHandle.standardInput.readDataToEndOfFile())
        let results: [[String: Any]] = inputs.map { text in
            ["title": TitleGenerator.sanitize(text).map { $0 as Any } ?? NSNull(),
             "prompt": TitleGenerator.promptText(text)]
        }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys]))
    }
}
