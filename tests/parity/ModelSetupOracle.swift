import Foundation

struct SetupInput: Decodable {
    let requiredModelReady: Bool
    let translationModelReady: Bool
    let translationEngineAvailable: Bool
    let choice: String?
    let variant: String
}

@main enum ModelSetupOracle {
    static func main() throws {
        let input = try JSONDecoder().decode([SetupInput].self, from: FileHandle.standardInput.readDataToEndOfFile())
        let results: [[String: Any]] = input.map { c in
            let choice: FirstRunModelSetupChoice?
            switch c.choice {
            case nil: choice = nil
            case "transcriptionOnly": choice = .transcriptionOnly
            case "recommended": choice = .recommended
            default: preconditionFailure("unknown choice")
            }
            let variant = TranslateModelVariant(rawValue: c.variant)!
            let bytes: Int64? = choice.map { FirstRunModelSetupPolicy.downloadBytes(
                choice: $0, requiredModelReady: c.requiredModelReady,
                translationModelReady: c.translationModelReady, translationAssetBytes: AssetManifest.translateModel(for: variant).sizeBytes) }
            return ["canEnterApp": FirstRunModelSetupPolicy.canEnterApp(
                requiredModelReady: c.requiredModelReady,
                translationModelReady: c.translationModelReady,
                translationEngineAvailable: c.translationEngineAvailable,
                choice: choice), "downloadBytes": bytes as Any? ?? NSNull()]
        }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys]))
    }
}
