import Foundation

private struct Input: Decodable { let name: String; let text: String }
@main struct Oracle {
    static func main() throws {
        let inputs = try JSONDecoder().decode([Input].self, from: FileHandle.standardInput.readDataToEndOfFile())
        let results: [[String: Any]] = inputs.map { input in
            let formatted = KoreanNumberFormatter.format(input.text)
            let (value, consumed) = KoreanNumberFormatter.parseNative(input.text)
            return ["name": input.name, "formatted": formatted, "twice": KoreanNumberFormatter.format(formatted),
                    "sino": KoreanNumberFormatter.parseSino(input.text).map { $0 as Any } ?? NSNull(),
                    "native": ["value": value.map { $0 as Any } ?? NSNull(), "consumed": consumed]]
        }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys]))
    }
}
