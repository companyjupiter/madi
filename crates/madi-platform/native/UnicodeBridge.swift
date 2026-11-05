// Swift String.lowercased uses the Swift toolchain's Unicode data and applies
// noncontextual mappings. NSString.lowercased differs (e.g. Greek final sigma).
// Keep only this platform/version-dependent transform in the native bridge.
import Foundation

@_cdecl("madi_swift_lowercase")
public func madiSwiftLowercase(
    _ source: UnsafePointer<UInt8>, _ count: Int,
    _ context: UnsafeMutableRawPointer,
    _ output: @convention(c) (UnsafeMutableRawPointer, UnsafePointer<UInt8>?, Int) -> Void
) {
    let input = UnsafeBufferPointer(start: source, count: count)
    let bytes = Array(String(decoding: input, as: UTF8.self).lowercased().utf8)
    bytes.withUnsafeBufferPointer { output(context, $0.baseAddress, $0.count) }
}
