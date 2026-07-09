import Foundation

public func getImageModel(provider: KnownImagesProvider, modelId: String) -> ImagesModel {
    guard let model = ImageModelsData[provider.rawValue]?[modelId] else {
        // API precondition for known-provider convenience lookup. Use the
        // string-provider overload when the provider/model pair is user input.
        fatalError("Unknown image model \(modelId) for provider \(provider.rawValue)")
    }
    return model
}

public func getImageModel(provider: String, modelId: String) -> ImagesModel? {
    ImageModelsData[provider]?[modelId]
}

public func getImageProviders() -> [KnownImagesProvider] {
    ImageModelsData.keys.compactMap { KnownImagesProvider(rawValue: $0) }
}

public func getImageModels(provider: KnownImagesProvider) -> [ImagesModel] {
    guard let values = ImageModelsData[provider.rawValue]?.values else {
        return []
    }
    return Array(values)
}
