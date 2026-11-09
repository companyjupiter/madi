// Test-only driver. Compiled with the unmodified shipping Swift parser.
import Foundation

@main
enum TranslateOracle {
    static func main() {
        if CommandLine.arguments.contains("--foundation-profile") {
            let decoded = String(data: Data([0xef, 0xbb, 0xbf, 0x61]), encoding: .utf8)!
            print(decoded == "a" ? "strip-leading-bom" : "preserve-bom")
            return
        }
        let input = [UInt8](FileHandle.standardInput.readDataToEndOfFile())
        var offset = 0
        func word() -> Int {
            precondition(offset + 4 <= input.count)
            let value = (0..<4).reduce(UInt32(0)) { $0 | UInt32(input[offset + $1]) << ($1 * 8) }
            offset += 4
            return Int(value)
        }
        var output = ""
        let cases = word()
        for c in 0..<cases {
            let preserve = input[offset] != 0
            offset += 1
            var parser = TranslateStreamParser(preserveNewlines: preserve)
            let chunks = word()
            for chunk in 0..<chunks {
                let length = word()
                let bytes = Data(input[offset..<offset + length])
                offset += length
                for event in parser.ingest(bytes) {
                    let kind: String
                    let value: String
                    switch event {
                    case .ready: kind = "ready"; value = ""
                    case .prefixReady(let slot): kind = "prefix"; value = String(slot)
                    case .capabilities(let caps): kind = "caps"; value = caps.joined(separator: "\0")
                    case .replyDelta(let text): kind = "delta"; value = text
                    case .turnComplete(let text): kind = "complete"; value = text
                    }
                    output += "\(c):\(chunk):\(kind):" + value.utf8.map { String(format: "%02x", $0) }.joined() + "\n"
                }
            }
        }
        FileHandle.standardOutput.write(Data(output.utf8))
    }
}
