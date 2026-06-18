import Foundation

enum EnginePathPolicy {
    static let pathListSeparator = ":"

    static func pathList(_ roots: [URL]) -> String {
        roots.map { normalizedPath($0) }.joined(separator: pathListSeparator)
    }

    static func streamWavIsAllowed(_ wav: URL, roots: [URL]) -> Bool {
        guard wav.pathExtension.lowercased() == "wav" else { return false }
        let wavPath = normalizedPath(wav)
        return roots.contains { root in
            let rootPath = normalizedPath(root)
            return wavPath == rootPath || wavPath.hasPrefix(rootPath + "/")
        }
    }

    private static func normalizedPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
