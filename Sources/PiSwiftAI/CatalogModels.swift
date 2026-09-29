import Foundation

public func getClassifierModel(provider: String, modelId: String) -> ClassifierModel? {
    ClassifierModelsData[provider]?[modelId]
}

public func getClassifierModels(provider: String) -> [ClassifierModel] {
    Array(ClassifierModelsData[provider]?.values ?? [:].values)
}

public func getModelsOfType(_ type: ModelType, provider: String? = nil) -> [AnyModel] {
    switch type {
    case .chat:
        return (provider.map { Array(ModelsData[$0]?.values ?? [:].values) }
            ?? ModelsData.values.flatMap { $0.values }).map(AnyModel.chat)
    case .image:
        return (provider.map { Array(ImageModelsData[$0]?.values ?? [:].values) }
            ?? ImageModelsData.values.flatMap { $0.values }).map(AnyModel.image)
    case .classifier:
        return (provider.map { Array(ClassifierModelsData[$0]?.values ?? [:].values) }
            ?? ClassifierModelsData.values.flatMap { $0.values }).map(AnyModel.classifier)
    }
}

public func getModelOfType(_ type: ModelType, provider: String, modelId: String) -> AnyModel? {
    switch type {
    case .chat: ModelsData[provider]?[modelId].map(AnyModel.chat)
    case .image: ImageModelsData[provider]?[modelId].map(AnyModel.image)
    case .classifier: ClassifierModelsData[provider]?[modelId].map(AnyModel.classifier)
    }
}

public func getAllModels(provider: String? = nil) -> [AnyModel] {
    ModelType.allCases.flatMap { getModelsOfType($0, provider: provider) }
}

public func getAllBuiltinModels(provider: String? = nil) -> [AnyModel] {
    getAllModels(provider: provider)
}

public func getBuiltinProviders() -> [KnownProvider] {
    let providers = getProviders()
    return providers.contains(.typesafe) ? providers : providers + [.typesafe]
}

public func getBuiltinModel(provider: KnownProvider, modelId: String) -> Model? {
    getModel(provider: provider.rawValue, modelId: modelId)
}

public func getBuiltinImageModel(provider: KnownProvider, modelId: String) -> ImageModel? {
    getImageModel(provider: provider.rawValue, modelId: modelId)
}

public func getBuiltinClassifierModel(provider: KnownProvider, modelId: String) -> ClassifierModel? {
    getClassifierModel(provider: provider.rawValue, modelId: modelId)
}

public func getBuiltinModels(provider: KnownProvider) -> [Model] {
    Array(ModelsData[provider.rawValue]?.values ?? [:].values)
}

public func getBuiltinImageModels(provider: KnownProvider) -> [ImageModel] {
    getImageModels(provider: provider.rawValue)
}

public func getBuiltinClassifierModels(provider: KnownProvider) -> [ClassifierModel] {
    getClassifierModels(provider: provider.rawValue)
}

public func hasApi(_ model: AnyModel, api: String) -> Bool {
    switch model {
    case .chat(let value): value.api.rawValue == api
    case .image(let value): value.api.rawValue == api
    case .classifier(let value): value.api.rawValue == api
    }
}

public func hasApi(_ model: AnyModel, api: Api) -> Bool { hasApi(model, api: api.rawValue) }
public func hasApi(_ model: AnyModel, api: ImageApi) -> Bool { hasApi(model, api: api.rawValue) }
public func hasApi(_ model: AnyModel, api: ClassifierApi) -> Bool { hasApi(model, api: api.rawValue) }

public func modelsAreEqual(_ a: AnyModel?, _ b: AnyModel?) -> Bool {
    guard let a, let b else { return false }
    return a.type == b.type && a.id == b.id && a.provider == b.provider
}

/// Later entries replace earlier entries of the same type and ID.
public func mergeCatalogModels(_ baseline: [AnyModel], _ updates: [AnyModel]) -> [AnyModel] {
    var merged = baseline
    for model in updates {
        if let index = merged.firstIndex(where: { $0.type == model.type && $0.id == model.id }) {
            merged[index] = model
        } else {
            merged.append(model)
        }
    }
    return merged
}
