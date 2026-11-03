import Foundation
struct Meeting: Decodable { let date: Double; let markdown: String }
struct Case: Decodable { let now: Double; let zone: String; let firstWeekday: Int; let minDays: Int; let meetings: [Meeting] }
struct Input: Decodable { let roots: [String]; let cases: [Case] }
@main enum WorkspaceOracle {
    static func node(_ node: FileNode, _ root: URL) -> [String: Any] {
        ["path": String(node.url.path.dropFirst(root.path.count+1)), "name": node.name,
         "directory": node.isDir, "transcript": node.isTranscript, "summary": node.isSummaryFile,
         "children": node.children.map { $0.map { self.node($0,root) } } as Any? ?? NSNull()]
    }
    static func bits(_ number: Double) -> String { String(format:"%016llx",number.bitPattern) }
    static func main() throws {
        let input = try JSONDecoder().decode(Input.self,from:FileHandle.standardInput.readDataToEndOfFile())
        let scans: [[String:Any]] = input.roots.map { path in
            let root = URL(fileURLWithPath:path), nodes = WorkspaceScan.run(root)
            return ["nodes":nodes.map { node($0,root) },"recent":NativeRecent(session:.init(workspace:.init(nodes:nodes))).read().map { String($0.path.dropFirst(root.path.count+1)) }]
        }
        let stats: [[String:Any]] = input.cases.map { c in
            var calendar=Calendar(identifier:.gregorian)
            calendar.timeZone=TimeZone(identifier:c.zone)!;calendar.firstWeekday=c.firstWeekday;calendar.minimumDaysInFirstWeek=c.minDays
            let meetings=c.meetings.compactMap { m -> (date: Date, parsed: TranscriptArchive.Parsed)? in
                guard let parsed=TranscriptArchive.parse(text:m.markdown) else {return nil}
                return (Date(timeIntervalSince1970:m.date),parsed)
            }
            let stats=WorkspaceAnalytics.aggregate(meetings:meetings,now:Date(timeIntervalSince1970:c.now),calendar:calendar)
            return ["count":stats.meetingCount,"seconds":bits(stats.totalSeconds),"words":stats.totalWords,"speakers":stats.speakerSum,
                    "thisWeek":stats.thisWeekCount,"trend":stats.weeklyTrend,"avgSeconds":bits(stats.avgSeconds),"avgSpeakers":bits(stats.avgSpeakers), "formattedWords":NumberFormatter.localizedString(from:NSNumber(value:stats.totalWords),number:.decimal), "averageLabel":String(format:"%.1f",stats.avgSpeakers)]
        }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:["scans":scans,"stats":stats],options:[.sortedKeys]))
    }
}
