import Foundation

struct AssetInput: Decodable {
    let memories: [UInt64]
    let overrides: [String?]
    let files: [Integrity]
    struct Integrity: Decodable {
        let path: String
        let size: Int64
        let sha256: String
        let hashInput: Bool
    }
}

@main enum AssetManifestOracle {
    static func main() throws {
        let input = try JSONDecoder().decode(AssetInput.self, from: FileHandle.standardInput.readDataToEndOfFile())
        func asset(_ asset: RemoteAsset) -> [String: Any] {
            ["name": asset.name, "url": asset.url.absoluteString, "sha256": asset.sha256,
             "sizeBytes": asset.sizeBytes, "approxRuntimeMemoryGb": asset.approxRuntimeMemoryGB as Any? ?? NSNull()]
        }
        // The override property reads process memory. Exercise it directly for
        // the actual host; use the original recommendation function for injected
        // threshold cases. Only the oracle's own environment is changed.
        let actualMemory = ProcessInfo.processInfo.physicalMemory
        var choices: [[String: Any]] = []
        for memory in input.memories {
            for override in input.overrides {
                if let override { setenv("MADI_TRANSLATE_MODEL", override, 1) }
                else { unsetenv("MADI_TRANSLATE_MODEL") }
                let native = AssetManifest.translateModelVariant
                let selected: TranslateModelVariant
                if memory == actualMemory || override?.lowercased() == "2b" || override?.lowercased() == "4b" { selected = native }
                else { selected = AssetManifest.recommendedTranslateModelVariant(physicalMemory: memory) }
                choices.append(["memory": memory, "override": override as Any? ?? NSNull(),
                                "recommended": AssetManifest.recommendedTranslateModelVariant(physicalMemory: memory).rawValue,
                                "selected": selected.rawValue, "engine": selected.engineExecutableName, "displayName": selected.displayName])
            }
        }
        let files: [[String: Any]] = input.files.map {
            let url = URL(fileURLWithPath: $0.path)
            return ["valid": AssetManifest.fileIsValid(at: url, expectedSize: $0.size, expectedSHA256: $0.sha256),
                    "hash": ($0.hashInput ? try? AssetManifest.sha256(of: url) : nil) as Any? ?? NSNull()]
        }
        let result: [String: Any] = ["assets": [AssetManifest.model, AssetManifest.translateModel4B, AssetManifest.translateModel2B].map(asset), "choices": choices, "files": files]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]))
    }
}
