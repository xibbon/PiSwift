import Foundation
@testable import PiSwiftAI

// Frozen v0.84.1 rows keep behavior tests independent of retired catalog entries.
func catalogV0841Model(provider: KnownProvider, modelId: String) -> Model {
    let url = Bundle.module.url(forResource: "catalog-v0841-regressions", withExtension: "json")!
    let models = try! JSONDecoder().decode([String: [String: Model]].self, from: Data(contentsOf: url))
    return models[provider.rawValue]![modelId]!
}
