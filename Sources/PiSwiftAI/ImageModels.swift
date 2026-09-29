import Foundation

public func getImageModel(provider: KnownProvider, modelId: String) -> ImageModel {
    guard let model = ImageModelsData[provider.rawValue]?[modelId] else {
        // API precondition for known-provider convenience lookup. Use the
        // string-provider overload when the provider/model pair is user input.
        fatalError("Unknown image model \(modelId) for provider \(provider.rawValue)")
    }
    return model
}

public func getImageModel(provider: String, modelId: String) -> ImageModel? {
    ImageModelsData[provider]?[modelId]
}

public func getImageProviders() -> [KnownProvider] {
    ImageModelsData.keys.compactMap { KnownProvider(rawValue: $0) }
}

public func getImageModels(provider: KnownProvider) -> [ImageModel] {
    guard let values = ImageModelsData[provider.rawValue]?.values else {
        return []
    }
    return Array(values)
}

public func getImageModels(provider: String) -> [ImageModel] {
    Array(ImageModelsData[provider]?.values ?? [:].values)
}
