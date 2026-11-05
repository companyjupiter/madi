import Foundation
// Read-only oracle data from the CoreFoundation Unicode table used by compare.
@_silgen_name("CFUniCharIsMemberOf")
func member(_ scalar: UInt32, _ set: UInt32) -> Bool
@main struct Main {
 static func main() throws {
  if CommandLine.arguments.contains("--extend") {
   let scalars=(UInt32(0)...UInt32(0x10ffff)).filter { UnicodeScalar($0) != nil && member($0,110) }
   FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:scalars))
   return
  }
  if CommandLine.arguments.contains("--fold") {
   var rows:[[String:Any]]=[]
   for value in UInt32(0)...UInt32(0x10ffff) {
    guard let scalar=UnicodeScalar(value) else { continue }
    let s=String(scalar)
    let f=s.folding(options:.caseInsensitive,locale:nil)
    if s != f { rows.append(["scalar":value,"fold":f]) }
   }
   FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:rows,options:[.sortedKeys]))
  } else {
   let pairs=try JSONDecoder().decode([[String]].self,from:FileHandle.standardInput.readDataToEndOfFile())
   let matches=pairs.map{$0[0].caseInsensitiveCompare($0[1]) == .orderedSame}
   FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:matches))
  }
 }
}
