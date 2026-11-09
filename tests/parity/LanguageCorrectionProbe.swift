import Foundation
@main struct Main {
 static func main() async throws {
  let a=CommandLine.arguments
  let source=URL(fileURLWithPath:a[4]);let original=try Data(contentsOf:source)
  let clip=try WavWriter.crop16kMonoPCM(source:source,start:2,end:5)
  defer {try? FileManager.default.removeItem(at:clip)}
  let text=await SessionOneShotTranscriber.transcribe(.init(binary:URL(fileURLWithPath:a[1]),model:URL(fileURLWithPath:a[2]),wav:clip,bpe:URL(fileURLWithPath:a[3]).appendingPathComponent("WHISPER_BPE.bin"),assets:URL(fileURLWithPath:a[3]),languageToken:50259))
  let result:[String:Any]=["text":text as Any? ?? NSNull(),"sourceUnchanged":original == (try Data(contentsOf:source)),"clipBytes":(try Data(contentsOf:clip)).count]
  FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]))
 }
}
