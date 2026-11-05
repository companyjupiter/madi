import Foundation

struct Input: Decodable {
    struct Line: Decodable { let id: UUID; let end: Double }
    struct Operation: Decodable {
        let kind: String
        let gap: Double?
        let delta: Double?
        let live: Bool?
        let lines: [Line]?
    }
    let settings: [String: Double]?
    let operations: [Operation]
}
@main enum Main {
    static func main() throws {
        let cases = try JSONDecoder().decode([Input].self, from: FileHandle.standardInput.readDataToEndOfFile())
        let output = cases.map { input -> [[String: Any]] in
            var model = TranscriptFollowModel()
            if let settings = input.settings {
                model.nearZone = settings["nearZone"] ?? model.nearZone
                model.pinTolerance = settings["pinTolerance"] ?? model.pinTolerance
                model.rearmZone = settings["rearmZone"] ?? model.rearmZone
                model.wheelDeadband = settings["wheelDeadband"] ?? model.wheelDeadband
            }
            return input.operations.map { operation -> [String: Any] in
                let lines = (operation.lines ?? []).map { TranscriptFollowModel.LineRef(id: $0.id, end: $0.end) }
                var action = TranscriptFollowModel.Action.none
                switch operation.kind {
                case "geometry": action = model.geometry(gap: operation.gap!, isLive: operation.live!, lines: lines)
                case "wheel": model.userScrolled(deltaY: operation.delta!, gap: operation.gap!)
                case "jump": model.programmaticJump()
                case "lines": model.linesChanged(lines)
                case "pill": action = model.pillTapped(lines)
                case "reset": model.reset()
                default: preconditionFailure("unknown operation")
                }
                return ["action": action == .pinToTail ? "pinToTail" : "none", "following": model.following,
                        "atBottom": model.atBottom, "unseen": model.unseen,
                        "seenTailID": model.seenTailID?.uuidString.lowercased() as Any? ?? NSNull(), "seenTailEnd": model.seenTailEnd]
            }
        }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]))
    }
}
