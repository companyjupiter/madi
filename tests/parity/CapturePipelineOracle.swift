// Appended verbatim to AudioCapture.swift in the generated oracle file. Swift's
// same-file private access drives the ACTUAL shipping ingest/consume/stop/abort.
// No sample-processing method is copied, patched or replaced for this oracle.
import CryptoKit

// UI-only dependency needed by AudioSource.label, never used by this gate.
enum UILanguage {
    case ko
    func callAsFunction(_ ko: String, _ en: String) -> String { ko }
}

extension AudioCapture {
    func oracleStart() {
        // Only native device admission is omitted. These are start()'s three
        // preprocessing statements; no AVAudioEngine tap or SCStream is opened.
        resetSegmenter()
        micPending.removeAll(); sysPending.removeAll()
        acceptsSamples = true
    }
    func oracleIngest(_ samples: [Int16], microphone: Bool) {
        ingest(samples, level: AudioCapture.rmsLevel(samples), mic: microphone)
    }
}

@main enum CapturePipelineOracle {
    final class Events { var values: [[String: Any]] = [] }
    static func describeFile(_ url: URL) -> [String: Any] {
        let data = try! Data(contentsOf: url)
        return ["name":url.lastPathComponent,"bytes":data.count,
                "sha256":SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()]
    }
    @MainActor static func configure(_ capture: AudioCapture, _ c: [String:Any], _ events: Events) {
        capture.source = AudioSource(rawValue:c["source"] as! String)!
        capture.segmentSeconds = c["segmentSeconds"] as! Double
        capture.overlapSeconds = c["overlapSeconds"] as! Double
        capture.firstSegmentSeconds = c["firstSegmentSeconds"] as! Double
        capture.previewSeconds = c["previewSeconds"] as! Double
        if c["previewEnabled"] as! Bool {
            capture.onPreview = { url, offset in
                var item = describeFile(url); item["type"]="preview"
                item["offsetBits"]=String(format:"%016llx",offset.bitPattern)
                events.values.append(item)
            }
        } else { capture.onPreview = nil }
    }
    @MainActor static func run(_ test: [String:Any]) -> ([String:Any], URL) {
        let capture = AudioCapture(); let events = Events()
        configure(capture,test["configuration"] as! [String:Any],events)
        capture.onLevel = { level in events.values.append(["type":"level","bits":String(format:"%08x",level.bitPattern)]) }
        capture.onSegment = { offset, url, speech in
            var item = describeFile(url); item["type"]="segment"; item["hadSpeech"]=speech
            item["offsetBits"]=String(format:"%016llx",offset.bitPattern)
            events.values.append(item)
        }
        var states: [[[String:Any]]] = []
        for op in test["operations"] as! [[String:Any]] {
            events.values.removeAll()
            switch op["type"] as! String {
            case "start": capture.oracleStart()
            case "pause": capture.pause()
            case "resume": capture.resume()
            case "stop": capture.stop()
            case "abort": capture.abort()
            case "configure": configure(capture,op["configuration"] as! [String:Any],events)
            case "ingest":
                let pattern = (op["pattern"] as! [Int]).map { Int16($0) }
                let pcm = (0..<(op["count"] as! Int)).map { pattern[$0 % pattern.count] }
                capture.oracleIngest(pcm,microphone:op["microphone"] as! Bool)
            default: fatalError("unknown capture operation")
            }
            states.append(events.values)
        }
        let directory = capture.segmentDirectory
        let files = try! FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil).sorted { $0.lastPathComponent < $1.lastPathComponent }.map(describeFile)
        return (["name":test["name"]!,"states":states,"files":files],directory)
    }
    @MainActor static func main() throws {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let cases = try JSONSerialization.jsonObject(with:input) as! [[String:Any]]
        var results: [[String:Any]] = []
        for test in cases {
            var (result,directory) = autoreleasepool { run(test) }
            result["directoryCleaned"] = !FileManager.default.fileExists(atPath:directory.path)
            results.append(result)
        }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:results,options:[.sortedKeys]))
    }
}
