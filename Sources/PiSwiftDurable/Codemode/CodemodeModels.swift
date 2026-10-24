import Foundation
import PiSwiftAI
import PiSwiftChord

/// Model services used by codemode. Hosts resolve credentials inside these methods.
public protocol CodemodeModels: DurableModels {
    func getModelsOfType(_ type: ModelType, provider: String?) -> [AnyModel]
    func getAvailableOfType(_ type: ModelType, provider: String?, context: ChordContext) async throws -> [AnyModel]
    func getModelOfType(_ type: ModelType, provider: String, id: String) -> AnyModel?
    func classify(model: ClassifierModel, context: ClassifierContext, operation: ChordContext) async throws -> ClassifierResult
    func generateImages(model: ImageModel, context: ImagesContext, operation: ChordContext) async throws -> AssistantImages
}

public extension CodemodeModels {
    func getModelOfType(_ type: ModelType, provider: String, id: String) -> AnyModel? {
        getModelsOfType(type, provider: provider).first { $0.id.utf16.elementsEqual(id.utf16) }
    }
}

internal let codemodeInternalPrefix = "pi.codemode."
internal let codemodeClassifyTool = "pi.codemode.models.classify"
internal let codemodeGenerateImagesTool = "pi.codemode.models.generateImages"
internal let codemodeCatalogGlobals = ["models.getModelsOfType", "models.getAvailableOfType", "models.getModelOfType"]
internal let codemodeModelsDescription = """
`models` (all functions return promises):
- `models.getModelsOfType(type, provider?)`, `models.getAvailableOfType(type, provider?)` (configured auth only), `models.getModelOfType(type, provider, id)`: the catalog; `type` is "chat", "image", or "classifier".
- `models.classify(model, { state: { ... }, images?: [{ type: "image", data, mimeType }], questions: { <id>: { type: "choice", instructions, criteria: { <label>: <meaning> } } | { type: "score", instructions, criteria: [<lowest level>, ..., <highest level>] } | { type: "bool", instructions, criteria: { true: <meaning>, false: <meaning> } } } })` resolves to `{ answers: { <id>: ... }, stopReason, errorMessage?, usage? }`.
- `models.generateImages(model, { input: [{ type: "text", text: <prompt> }, ...optional { type: "image", data, mimeType }] })` resolves to `{ output: [image blocks], stopReason, errorMessage?, usage? }`; show each image with `image(block)`.
At most 4 classify/generateImages calls run at once; more wait.
"""

internal func codemodeCatalogCall(name: String, args: JSONValue?, models: any DurableModels,
                                  context: ChordContext) async throws -> JSONValue? {
    guard let models = models as? any CodemodeModels else {
        throw TaskDefinitionError("The host must supply CodemodeModels for models.* calls")
    }
    let list = args?.arrayValue ?? []
    guard let typeName = list.first?.stringValue, let type = ModelType(rawValue: typeName) else {
        throw TaskDefinitionError("Unknown model type. Use \"chat\", \"image\", or \"classifier\".")
    }
    let providerValue: JSONValue? = list.count > 1 ? list[1] : nil
    if let providerValue, providerValue != .null, providerValue.stringValue == nil {
        throw TaskDefinitionError("provider must be a string")
    }
    let provider = providerValue?.stringValue
    if name == "models.getModelsOfType" {
        return .array(try models.getModelsOfType(type, provider: provider).map(codemodeModelInfo))
    }
    if name == "models.getAvailableOfType" {
        return .array(try await models.getAvailableOfType(type, provider: provider, context: context).map(codemodeModelInfo))
    }
    guard let provider, list.count > 2, let id = list[2].stringValue else {
        throw TaskDefinitionError("models.getModelOfType(type, provider, id) expects three strings. The provider and the id are separate arguments, for example models.getModelOfType(\"classifier\", \"typesafe\", \"jev-latest\").")
    }
    return try models.getModelOfType(type, provider: provider, id: id).map(codemodeModelInfo)
}

private func codemodeModelInfo(_ model: AnyModel) throws -> JSONValue {
    var object = try JSONValue(encoding: model).objectValue!
    object.removeValue(forKey: "headers")
    return .object(object)
}

internal func codemodeModelTools() throws -> [ToolRegistration] {
    let parameters: JSONObject = ["type": "object", "properties": ["model": [:], "context": [:]], "required": ["model", "context"]]
    return try [codemodeClassifyTool, codemodeGenerateImagesTool].map { name in
        try ToolRegistration(name: name, description: name == codemodeClassifyTool ? "models.classify() of code mode scripts." : "models.generateImages() of code mode scripts.",
            parameters: parameters, callers: [.tools], structuredOutputSchema: [:]) { args, api, context in
            guard let models = api.models as? any CodemodeModels else {
                throw TaskDefinitionError("The host must supply CodemodeModels for models.* calls")
            }
            let type: ModelType = name == codemodeClassifyTool ? .classifier : .image
            let label = name == codemodeClassifyTool ? "models.classify" : "models.generateImages"
            let supplied = args.objectValue?["model"]?.objectValue
            let hint = "List the \(type.rawValue) models you can use with models.getAvailableOfType(\"\(type.rawValue)\")."
            guard let provider = supplied?["provider"]?.stringValue, let id = supplied?["id"]?.stringValue else {
                throw TaskDefinitionError("\(label)() expects a \(type.rawValue) model as its first argument. models.getModelOfType() returns undefined for an unknown provider or id. \(hint)")
            }
            guard let model = models.getModelOfType(type, provider: provider, id: id) else {
                if let actual = ModelType.allCases.first(where: { $0 != type && models.getModelOfType($0, provider: provider, id: id) != nil }) {
                    throw TaskDefinitionError("\"\(provider)/\(id)\" is a \(actual.rawValue) model, not a \(type.rawValue) model. \(hint)")
                }
                throw TaskDefinitionError("Unknown \(type.rawValue) model \"\(provider)/\(id)\". \(hint)")
            }
            let input = args.objectValue?["context"]
            switch model {
            case .classifier(let classifier):
                let checked = try codemodeClassifierContext(input)
                let result = try await models.classify(model: classifier, context: checked, operation: context)
                return codemodeModelResult(label: "classify \(provider)/\(id)", value: codemodeClassifierValue(result),
                    stopReason: result.stopReason.rawValue, error: result.errorMessage, usage: result.usage)
            case .image(let image):
                let checked = try codemodeImagesContext(input)
                let result = try await models.generateImages(model: image, context: checked, operation: context)
                var value: JSONObject = ["api": .string(result.api.rawValue), "provider": .string(result.provider), "model": .string(result.model),
                    "output": .array(try result.output.map { try durableJSON(fromOrdered: contentBlockToOrderedJSON($0)) }),
                    "stopReason": .string(result.stopReason.rawValue), "timestamp": .number(Double(result.timestamp))]
                value["responseId"] = result.responseId.map(JSONValue.string)
                value["errorMessage"] = result.errorMessage.map(JSONValue.string)
                value["usage"] = result.usage.map(usageValue)
                return codemodeModelResult(label: "generateImages \(provider)/\(id)", value: .object(value),
                    stopReason: result.stopReason.rawValue, error: result.errorMessage, usage: result.usage)
            default: throw TaskDefinitionError("The host returned the wrong model type")
            }
        }
    }
}

private func codemodeModelResult(label: String, value: JSONValue, stopReason: String, error: String?, usage: Usage?) -> ToolExecutionResult {
    ToolExecutionResult(output: [.text(.init(text: stopReason == "stop" ? "\(label) done" : "\(label) \(stopReason): \(error ?? "")"))],
        structuredOutput: value, isError: stopReason == "stop" ? nil : true, usage: usage)
}

private func codemodeClassifierValue(_ result: ClassifierResult) -> JSONValue {
    var answers = JSONObject()
    for (id, answer) in result.answers {
        switch answer {
        case .bool(let probability): answers[id] = ["probability": .number(probability)]
        case .choice(let choice, let probabilities, let confidence):
            answers[id] = ["choice": .string(choice), "probabilities": .object(JSONObject(probabilities.sorted { $0.key < $1.key }.map { ($0.key, .number($0.value)) })), "confidence": .number(confidence)]
        case .score(let score, let confidence): answers[id] = ["score": .number(score), "confidence": .number(confidence)]
        }
    }
    var value: JSONObject = ["api": .string(result.api.rawValue), "provider": .string(result.provider), "model": .string(result.model),
        "answers": .object(answers), "stopReason": .string(result.stopReason.rawValue), "timestamp": .number(Double(result.timestamp))]
    value["errorMessage"] = result.errorMessage.map(JSONValue.string); value["usage"] = result.usage.map(usageValue)
    return .object(value)
}

private let classifierShape = "{ state: { ... }, images?: [{ type: \"image\", data: <base64>, mimeType }], questions: { <id>: { type: \"choice\", instructions, criteria: { <label>: <meaning> } } | { type: \"score\", instructions, criteria: [<lowest level>, ..., <highest level>] } | { type: \"bool\", instructions, criteria: { true: <meaning>, false: <meaning> } } } }"
internal func codemodeClassifierContext(_ value: JSONValue?) throws -> ClassifierContext {
    func fail(_ message: String) -> TaskDefinitionError { TaskDefinitionError("models.classify() \(message). Expected context: \(classifierShape).") }
    guard let object = value?.objectValue else { throw fail("expects a context object as its second argument") }
    guard let state = object["state"]?.objectValue else { throw fail("context.state must be an object") }
    var images: [ImageContent]?
    if let input = object["images"] {
        guard let list = input.arrayValue else { throw fail("context.images must be an array") }
        images = try list.enumerated().map { index, item in
            guard let image = item.objectValue, image["type"] == "image", let data = image["data"]?.stringValue, let mime = image["mimeType"]?.stringValue else {
                throw fail("context.images[\(index)] must be an image block")
            }
            return ImageContent(data: data, mimeType: mime)
        }
    }
    guard let questions = object["questions"]?.objectValue, !questions.isEmpty else { throw fail("context.questions must map question IDs to questions") }
    let entries: [(String, ClassifierQuestion)] = try questions.map { id, value in
        guard let question = value.objectValue else { throw fail("context.questions.\(id) must be a question object") }
        guard let instructions = question["instructions"]?.stringValue else { throw fail("context.questions.\(id).instructions must be a string") }
        let criteria = question["criteria"]
        switch question["type"]?.stringValue {
        case "choice":
            guard let object = criteria?.objectValue, !object.isEmpty, object.allSatisfy({ $0.value.stringValue != nil }) else {
                throw fail("context.questions.\(id) is a \"choice\" question, so criteria must map each label to its meaning")
            }
            return (id, .choice(instructions: instructions, criteria: .init(object.map { ($0.key, $0.value.stringValue!) })))
        case "score":
            guard let list = criteria?.arrayValue, !list.isEmpty, list.allSatisfy({ $0.stringValue != nil }) else {
                throw fail("context.questions.\(id) is a \"score\" question, so criteria must list the levels as strings, lowest first")
            }
            return (id, .score(instructions: instructions, criteria: list.map { $0.stringValue! }))
        case "bool":
            guard let object = criteria?.objectValue, let yes = object["true"]?.stringValue, let no = object["false"]?.stringValue else {
                throw fail("context.questions.\(id) is a \"bool\" question, so criteria must be { true: string, false: string }")
            }
            return (id, .bool(instructions: instructions, trueCriterion: yes, falseCriterion: no))
        default: throw fail("context.questions.\(id).type must be \"choice\", \"score\", or \"bool\"")
        }
    }
    let dictionary = try foundationJSON(from: .object(state)) as! [String: Any]
    return ClassifierContext(state: dictionary.mapValues(AnyCodable.init), questions: .init(entries), images: images)
}

internal func codemodeImagesContext(_ value: JSONValue?) throws -> ImagesContext {
    func fail(_ message: String) -> TaskDefinitionError {
        TaskDefinitionError("models.generateImages() \(message). Expected context: { input: [{ type: \"text\", text: <prompt> }, ...optional { type: \"image\", data: <base64>, mimeType } references] }.")
    }
    guard let list = value?.objectValue?["input"]?.arrayValue, !list.isEmpty else { throw fail("context.input must be a non-empty array of blocks") }
    let blocks: [ContentBlock] = try list.enumerated().map { index, value in
        let object = value.objectValue
        if object?["type"] == "text", let text = object?["text"]?.stringValue { return .text(.init(text: text)) }
        if object?["type"] == "image", let data = object?["data"]?.stringValue, let mime = object?["mimeType"]?.stringValue { return .image(.init(data: data, mimeType: mime)) }
        throw fail("context.input[\(index)] must be a text or image block")
    }
    return ImagesContext(input: blocks)
}
