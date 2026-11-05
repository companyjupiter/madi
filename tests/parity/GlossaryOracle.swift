import Foundation

struct Operation: Decodable {
    let kind: String
    let wrong: String?
    let right: String?
    let minHits: Int?
    let enabled: Bool?
}
struct Case: Decodable { let raw: String?; let operations: [Operation]; let queries: [String] }
@main enum GlossaryOracle {
    static func json<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: .fragmentsAllowed)
    }
    static func snapshot(_ glossary: Glossary, _ queries: [String]) throws -> [String: Any] {
        ["stored": try json(glossary), "active": try json(glossary.activeEntries),
         "display": try json(glossary.parityDisplayEntries),
         "exact": try queries.map { try json(glossary.exact($0)) }]
    }
    static func main() throws {
        let cases = try JSONDecoder().decode([Case].self, from: FileHandle.standardInput.readDataToEndOfFile())
        var results: [[String: Any]] = []
        for c in cases {
            let decoded = c.raw.flatMap { try? JSONDecoder().decode(Glossary.self, from: Data($0.utf8)) }
            var glossary = decoded ?? Glossary()
            var states = [try snapshot(glossary, c.queries)]
            for op in c.operations {
                switch op.kind {
                case "learn": glossary.learn(wrong: op.wrong!, right: op.right!)
                case "clear": glossary.clear()
                case "forget": glossary.forget(op.wrong!)
                case "enabled": glossary.enabled = op.enabled!
                case "minHits": glossary.minHits = op.minHits!
                default: fatalError("unknown operation")
                }
                states.append(try snapshot(glossary, c.queries))
            }
            results.append(["decoded": c.raw == nil || decoded != nil, "states": states])
        }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys]))
    }
}
