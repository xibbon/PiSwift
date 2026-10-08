import Foundation
import CoreFoundation
import PiSwiftAI
import PiSwiftAgent

/// The catalog, classifier, and image operations scripts can use.
public protocol CodemodeModelRuntime: Sendable {
    func getModelsOfType(_ type: ModelType, provider: String?) -> [AnyModel]
    func getAvailableOfType(_ type: ModelType, provider: String?) async -> [AnyModel]
    func getModelOfType(_ type: ModelType, provider: String, modelId: String) -> AnyModel?
    func generateImages(_ model: ImageModel, context: ImagesContext, options: ImagesOptions?) async -> AssistantImages
    func classify(_ model: ClassifierModel, context: ClassifierContext, options: ClassifierOptions?) async -> ClassifierResult
}

// Keep classifier-only host implementations source compatible.
public extension CodemodeModelRuntime {
    func generateImages(_ model: ImageModel, context: ImagesContext, options: ImagesOptions?) async -> AssistantImages {
        AssistantImages(api: model.api, provider: model.provider, model: model.id,
                        stopReason: .error, errorMessage: "Image generation is unavailable")
    }
}

extension ModelRegistry: CodemodeModelRuntime {}

private enum CodemodeBridgeError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let text) = self { return text }
        return nil
    }
}

private func parseJSON(_ text: String) throws -> AnyCodable {
    try JSONDecoder().decode(AnyCodable.self, from: Data(text.utf8))
}

private func jsonText(_ value: AnyCodable) throws -> String {
    let data = try JSONEncoder().encode(value)
    return String(data: data, encoding: .utf8) ?? "null"
}

private func previewJSON(_ text: String) -> String {
    CodemodeNestedCall.preview(text, limit: 200)
}

private func textOf(_ result: AgentToolResult) -> String {
    result.content.compactMap { block -> String? in
        if case .text(let item) = block { return item.text }
        return nil
    }.joined(separator: "\n")
}

private func modelInfo(_ model: AnyModel) throws -> AnyCodable {
    let data = try JSONEncoder().encode(model)
    guard var fields = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw CodemodeBridgeError.message("Could not encode model")
    }
    fields.removeValue(forKey: "headers")
    return AnyCodable(fields)
}

private func modelType(_ value: Any?) throws -> ModelType {
    if let raw = value as? String, let type = ModelType(rawValue: raw) { return type }
    let shown = value.map { (try? jsonText(AnyCodable($0))) ?? "undefined" } ?? "undefined"
    throw CodemodeBridgeError.message("Unknown model type \(shown). Use \"chat\", \"image\", or \"classifier\".")
}

private func provider(_ value: Any?) throws -> String? {
    guard let value, !(value is NSNull) else { return nil }
    guard let string = value as? String else { throw CodemodeBridgeError.message("provider must be a string") }
    return string
}

private func arguments(_ text: String) throws -> [AnyCodable] {
    guard let values = try parseJSON(text).value as? [Any] else {
        throw CodemodeBridgeError.message("Invalid global arguments")
    }
    return values.map(AnyCodable.init)
}

private func describeValue(_ value: OrderedJSON?) -> String {
    guard let value else { return "undefined" }
    switch value {
    case .null: return "null"
    case .array(let items): return items.isEmpty ? "an empty array" : "an array"
    case .object(let items):
        let keys = items.map { $0.0 }
        return keys.isEmpty ? "{}" : "{ \(keys.prefix(6).joined(separator: ", "))\(keys.count > 6 ? ", ..." : "") }"
    case .string: return "a string"
    case .bool: return "a boolean"
    default: return "a number"
    }
}

private let classifierContextShape = #"{ state: { ... }, images?: [{ type: "image", data: <base64>, mimeType }], questions: { <id>: { type: "choice", instructions, criteria: { <label>: <meaning> } } | { type: "score", instructions, criteria: [<lowest level>, ..., <highest level>] } | { type: "bool", instructions, criteria: { true: <meaning>, false: <meaning> } } } }"#

private func classifierContext(_ ordered: OrderedJSON?) throws -> ClassifierContext {
    func fail(_ problem: String) -> CodemodeBridgeError {
        .message("models.classify() \(problem). Expected context: \(classifierContextShape). See \"Classify\" in \(CODEMODE_DOCS_PATH).")
    }
    guard let ordered, ordered.objectEntries != nil else {
        throw fail("expects a context object as its second argument, got \(describeValue(ordered))")
    }
    guard let state = ordered["state"], state.objectEntries != nil else {
        throw fail("context.state must be an object, got \(describeValue(ordered["state"]))")
    }
    var images: [ImageContent]?
    if let value = ordered["images"] {
        guard case .array(let blocks) = value else {
            throw fail("context.images must be an array, got \(describeValue(value))")
        }
        images = try blocks.enumerated().map { index, block in
            guard block.objectEntries != nil, block["type"]?.stringValue == "image",
                  let data = block["data"]?.stringValue, let mimeType = block["mimeType"]?.stringValue else {
                throw fail("context.images[\(index)] must be an image block, got \(describeValue(block))")
            }
            return ImageContent(data: data, mimeType: mimeType)
        }
    }
    guard let questions = ordered["questions"]?.objectEntries, !questions.isEmpty else {
        throw fail("context.questions must map question IDs to questions, got \(describeValue(ordered["questions"]))")
    }
    let stateValue = try parseJSON(state.serialized())
    let stateFields = (stateValue.value as? [String: Any] ?? [:]).mapValues(AnyCodable.init)
    var parsedQuestions: [(String, ClassifierQuestion)] = []
    for (name, question) in questions {
        let at = "context.questions.\(name)"
        guard question.objectEntries != nil else { throw fail("\(at) must be a question object, got \(describeValue(question))") }
        guard let instructions = question["instructions"]?.stringValue else { throw fail("\(at).instructions must be a string") }
        switch question["type"]?.stringValue {
        case "choice":
            guard let criteria = question["criteria"]?.objectEntries, !criteria.isEmpty,
                  criteria.allSatisfy({ $0.1.stringValue != nil }) else {
                throw fail("\(at) is a \"choice\" question, so criteria must map each label to its meaning")
            }
            parsedQuestions.append((name, .choice(instructions: instructions,
                criteria: ClassifierChoiceCriteria(criteria.map { ($0.0, $0.1.stringValue!) }))))
        case "score":
            guard case .array(let criteria)? = question["criteria"], !criteria.isEmpty,
                  criteria.allSatisfy({ $0.stringValue != nil }) else {
                throw fail("\(at) is a \"score\" question, so criteria must list the levels as strings, lowest first")
            }
            parsedQuestions.append((name, .score(instructions: instructions, criteria: criteria.compactMap(\.stringValue))))
        case "bool":
            guard let yes = question["criteria"]?["true"]?.stringValue,
                  let no = question["criteria"]?["false"]?.stringValue else {
                throw fail("\(at) is a \"bool\" question, so criteria must be { true: string, false: string }")
            }
            parsedQuestions.append((name, .bool(instructions: instructions, trueCriterion: yes, falseCriterion: no)))
        default:
            throw fail("\(at).type must be \"choice\", \"score\", or \"bool\", got \(question["type"]?.serialized() ?? "undefined")")
        }
    }
    return ClassifierContext(state: stateFields, questions: ClassifierQuestions(parsedQuestions), images: images)
}

private func imagesContext(_ context: OrderedJSON?) throws -> ImagesContext {
    func fail(_ problem: String) -> CodemodeBridgeError {
        .message("models.generateImages() \(problem). Expected context: { input: [{ type: \"text\", text: <prompt> }, ...optional { type: \"image\", data: <base64>, mimeType } references] }. See \"Generate images\" in \(CODEMODE_DOCS_PATH).")
    }
    guard let context, context.objectEntries != nil else {
        throw fail("expects a context object as its second argument, got \(describeValue(context))")
    }
    guard case .array(let input)? = context["input"], !input.isEmpty else {
        throw fail("context.input must be a non-empty array of blocks, got \(describeValue(context["input"]))")
    }
    let blocks = try input.enumerated().map { index, block -> ContentBlock in
        if block["type"]?.stringValue == "text", let text = block["text"]?.stringValue {
            return .text(TextContent(text: text))
        }
        if block["type"]?.stringValue == "image", let data = block["data"]?.stringValue,
           let mime = block["mimeType"]?.stringValue { return .image(ImageContent(data: data, mimeType: mime)) }
        throw fail("context.input[\(index)] must be a text or image block, got \(describeValue(block))")
    }
    return ImagesContext(input: blocks)
}

private func imagesResult(_ result: AssistantImages) -> AnyCodable {
    var fields: [String: Any] = ["api": result.api.rawValue, "provider": result.provider,
        "model": result.model, "stopReason": result.stopReason.rawValue, "timestamp": result.timestamp,
        "output": result.output.map { block -> [String: Any] in
            switch block {
            case .text(let text): return ["type": "text", "text": text.text]
            case .image(let image): return ["type": "image", "data": image.data, "mimeType": image.mimeType]
            default: return [:]
            }
        }]
    if let id = result.responseId { fields["responseId"] = id }
    if let error = result.errorMessage { fields["errorMessage"] = error }
    if let usage = result.usage { fields["usage"] = usageInfo(usage) }
    return AnyCodable(fields)
}

private func usageInfo(_ usage: Usage) -> [String: Any] {
    var reported: [String: Any] = [
        "input": usage.input, "output": usage.output,
        "cacheRead": usage.cacheRead, "cacheWrite": usage.cacheWrite,
        "totalTokens": usage.totalTokens,
        "cost": ["input": usage.cost.input, "output": usage.cost.output,
             "cacheRead": usage.cost.cacheRead, "cacheWrite": usage.cost.cacheWrite,
             "total": usage.cost.total]
    ]
    if let value = usage.cacheWrite1h { reported["cacheWrite1h"] = value }
    if let value = usage.reasoning { reported["reasoning"] = value }
    return reported
}

private func classifierResult(_ result: ClassifierResult) -> AnyCodable {
    let answers: [String: Any] = result.answers.mapValues { answer in
        switch answer {
        case .choice(let choice, let probabilities, let confidence):
            return ["type": "choice", "choice": choice, "probabilities": probabilities, "confidence": confidence]
        case .score(let score, let confidence):
            return ["type": "score", "score": score, "confidence": confidence]
        case .bool(let probability):
            return ["type": "bool", "probability": probability]
        }
    }
    var fields: [String: Any] = [
        "api": result.api.rawValue, "provider": result.provider, "model": result.model,
        "answers": answers, "stopReason": result.stopReason.rawValue, "timestamp": result.timestamp
    ]
    if let message = result.errorMessage { fields["errorMessage"] = message }
    if let usage = result.usage {
        fields["usage"] = usageInfo(usage)
    }
    return AnyCodable(fields)
}

private actor ClassifyLimit {
    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if active >= 4 {
            await withCheckedContinuation { waiting.append($0) }
        } else {
            active += 1
        }
    }

    func release() {
        if !waiting.isEmpty { waiting.removeFirst().resume() }
        else { active -= 1 }
    }
}

private actor CodemodeCallState {
    private var calls: [CodemodeNestedCall] = []
    private var usage: Usage?
    private var modelCallCount = 0
    private var generatedImages = 0
    private var closed = false
    private let toolCallId: String
    private let onUpdate: AgentToolUpdateCallback?

    init(toolCallId: String, onUpdate: AgentToolUpdateCallback?) {
        self.toolCallId = toolCallId
        self.onUpdate = onUpdate
    }

    private func publish() {
        let rows = calls.map { row -> [String: Any] in
            var fields: [String: Any] = ["id": row.id, "name": row.name, "args": row.args,
                                         "status": row.status.rawValue]
            if let duration = row.durationMs { fields["durationMs"] = duration }
            if let error = row.error { fields["error"] = error }
            if let cost = row.cost { fields["cost"] = cost }
            return fields
        }
        onUpdate?(AgentToolResult(content: [], details: AnyCodable(["calls": rows])))
    }

    func start(id: String, name: String, args: String) -> Int {
        guard !closed else { return -1 }
        calls.append(CodemodeNestedCall(id: id, name: name, args: previewJSON(args), status: .running))
        publish()
        return calls.count - 1
    }

    func startTool(name: String, args: String) -> Int {
        start(id: "\(toolCallId)/?", name: name, args: args)
    }

    func nextModelCallID(_ name: String) -> String {
        modelCallCount += 1
        return "\(toolCallId)/\(name)/\(modelCallCount)"
    }

    func addGeneratedImages(_ count: Int) { if !closed { generatedImages += count } }

    func finish(index: Int, id: String? = nil, status: CodemodeNestedCallStatus,
                durationMs: Double, error: String? = nil, cost: Double? = nil, usage newUsage: Usage? = nil) {
        guard !closed, calls.indices.contains(index) else { return }
        if let id { calls[index].id = id }
        calls[index].status = status
        calls[index].durationMs = durationMs
        calls[index].error = error
        calls[index].cost = cost
        if let newUsage { usage = usage.map { combineUsage($0, newUsage) } ?? newUsage }
        publish()
    }

    func complete() -> (calls: [CodemodeNestedCall], usage: Usage?, generatedImages: Int) {
        closed = true
        for index in calls.indices where calls[index].status == .running { calls[index].status = .cancelled }
        return (calls, usage, generatedImages)
    }
}

/// Replay writes from the active branch, from root to leaf.
public func readCodemodeStore(_ branch: [SessionEntry]) -> [String: AnyCodable] {
    var store: [String: AnyCodable] = [:]
    for entry in branch {
        guard case .custom(let custom) = entry,
              custom.customType == CODEMODE_STORE_ENTRY_TYPE,
              let data = custom.data?.value as? [String: Any],
              let set = data["set"] as? [String: Any],
              let deleted = data["delete"] as? [String] else { continue }
        for key in deleted { store.removeValue(forKey: key) }
        for (key, value) in set { store[key] = AnyCodable(value) }
    }
    return store
}

private func success(_ value: AnyCodable?) -> CodemodeRuntimeReply {
    CodemodeRuntimeReply(ok: true, payloadJSON: value.flatMap { try? jsonText($0) })
}

private func failure(_ message: String) -> CodemodeRuntimeReply {
    CodemodeRuntimeReply(ok: false, payloadJSON: message)
}

private func handleTool(_ call: CodemodeRuntimeCall, tool: AgentTool?, context: CustomToolContext?,
                        state: CodemodeCallState) async -> CodemodeRuntimeReply {
    guard let tool, let context else { return failure("Tool calls need a session") }
    let started = Date()
    let argsJSON = call.argsJSON ?? "{}"
    let index = await state.startTool(name: tool.name, args: call.argsJSON ?? "")
    do {
        guard let args = try parseJSON(argsJSON).value as? [String: Any] else {
            throw CodemodeBridgeError.message("Tool arguments must be an object")
        }
        let outcome = await context.executeTool(name: tool.name, args: args.mapValues(AnyCodable.init),
                                                 options: ExecuteToolOptions(signal: call.signal,
                                                     argumentsJSON: parseToolArgumentsSource(argsJSON)))
        let body = textOf(outcome.result)
        let status: CodemodeNestedCallStatus = outcome.isError ? (call.signal.isCancelled ? .cancelled : .error) : .ok
        await state.finish(index: index, id: outcome.toolCall.id, status: status,
                           durationMs: Date().timeIntervalSince(started) * 1000,
                           error: outcome.isError ? (body.isEmpty ? "Tool \"\(tool.name)\" failed" : body) : nil)
        if let structured = outcome.result.structuredContent, tool.outputSchema != nil {
            return success(structured)
        }
        if outcome.isError { return failure(body.isEmpty ? "Tool \"\(tool.name)\" failed" : body) }
        return success(AnyCodable(body))
    } catch {
        let message = error.localizedDescription
        await state.finish(index: index, status: call.signal.isCancelled ? .cancelled : .error,
                           durationMs: Date().timeIntervalSince(started) * 1000, error: message)
        return failure(message)
    }
}

private func handleGlobal(_ call: CodemodeRuntimeCall, callable: [AgentTool],
                          samples: [String: String], options: CodemodeToolOptions,
                          modelRuntime: (any CodemodeModelRuntime)?, state: CodemodeCallState,
                          limit: ClassifyLimit) async -> CodemodeRuntimeReply {
    do {
        let args = try arguments(call.argsJSON ?? "[]")
        let raw = args.map { $0.value }
        switch call.name {
        case "searchTools":
            guard let query = raw.first as? String else { throw CodemodeBridgeError.message("searchTools() expects a query string") }
            let fields = raw.count > 1 ? raw[1] as? [String: Any] : nil
            let requested = fields?["limit"]
            var count = DEFAULT_TOOL_SEARCH_LIMIT
            if let requested, !(requested is NSNull) {
                guard let value = requested as? NSNumber,
                      CFGetTypeID(value) != CFBooleanGetTypeID(),
                      value.doubleValue.isFinite, value.doubleValue.rounded() == value.doubleValue,
                      value.doubleValue > 0 else {
                    throw CodemodeBridgeError.message("searchTools() limit must be a positive integer")
                }
                count = value.doubleValue >= Double(Int.max) ? Int.max : value.intValue
            }
            let namespace = fields?["namespace"]
            if let namespace, !(namespace is NSNull), !(namespace is String) {
                throw CodemodeBridgeError.message("searchTools() namespace must be a string")
            }
            let filter = namespace as? String
            let documents = callable.compactMap { tool -> ToolSearchDocument? in
                let toolNamespace = options.getToolNamespace?(tool.name)
                if let filter, !filter.isEmpty, !(toolNamespace.map { matchesToolNamespace(name: filter, namespace: $0.name) } ?? false) { return nil }
                let info = ToolInfo(name: tool.name, description: tool.description,
                                    parameters: tool.parameters, namespace: toolNamespace)
                return createToolSearchDocument(info, namespace: toolNamespace)
            }
            let matches = Bm25Ranker().rank(query, documents: documents, limit: count)
            return success(AnyCodable(matches.map { match in
                ["name": toCodemodeIdentifier(match.name), "description": samples[match.name] ?? ""]
            }))
        case "describeTool":
            guard let name = raw.first as? String else { throw CodemodeBridgeError.message("describeTool() expects a tool name") }
            guard let tool = callable.first(where: {
                $0.name == name || toCodemodeIdentifier($0.name) == name
            }) else { return success(nil) }
            return success(AnyCodable(samples[tool.name] ?? ""))
        case "describeNamespace":
            guard let name = raw.first as? String else { throw CodemodeBridgeError.message("describeNamespace() expects a namespace name") }
            var namespace: ToolNamespace?
            var names: [String] = []
            for tool in callable {
                guard let candidate = options.getToolNamespace?(tool.name),
                      matchesToolNamespace(name: name, namespace: candidate.name) else { continue }
                if namespace == nil { namespace = candidate }
                names.append(toCodemodeIdentifier(tool.name))
            }
            guard let namespace else { return success(nil) }
            var fields: [String: Any] = ["name": namespace.name, "tools": names]
            if let description = namespace.description, !description.isEmpty { fields["description"] = description }
            if let instructions = namespace.instructions, !instructions.isEmpty { fields["instructions"] = instructions }
            return success(AnyCodable(fields))
        case "models.getModelsOfType", "models.getAvailableOfType", "models.getModelOfType", "models.classify", "models.generateImages":
            guard let models = modelRuntime else { throw CodemodeBridgeError.message("Model API is unavailable") }
            switch call.name {
            case "models.getModelsOfType":
                return success(AnyCodable(try models.getModelsOfType(modelType(raw.first), provider: try provider(raw.dropFirst().first)).map { try modelInfo($0).value }))
            case "models.getAvailableOfType":
                let found = await models.getAvailableOfType(try modelType(raw.first), provider: try provider(raw.dropFirst().first))
                return success(AnyCodable(try found.map { try modelInfo($0).value }))
            case "models.getModelOfType":
                guard raw.count >= 3, let providerName = raw[1] as? String,
                      let id = raw[2] as? String else {
                    let ordered = try OrderedJSON.parse(call.argsJSON ?? "[]")
                    guard case .array(let values) = ordered else { return failure("Invalid global arguments") }
                    throw CodemodeBridgeError.message("models.getModelOfType(type, provider, id) expects three strings, got (\(values.map { describeValue($0) }.joined(separator: ", "))). The provider and the id are separate arguments, for example models.getModelOfType(\"classifier\", \"typesafe\", \"jev-latest\").")
                }
                guard let found = models.getModelOfType(try modelType(raw.first), provider: providerName, modelId: id) else {
                    return success(nil)
                }
                return success(try modelInfo(found))
            default:
                let type: ModelType = call.name == "models.classify" ? .classifier : .image
                let article = type == .image ? "an image" : "a classifier"
                let listHint = "List the \(type.rawValue) models you can use with models.getAvailableOfType(\"\(type.rawValue)\")."
                guard case .array(let ordered) = try OrderedJSON.parse(call.argsJSON ?? "[]") else { return failure("Invalid global arguments") }
                guard let reference = raw.first as? [String: Any],
                      let providerName = reference["provider"] as? String,
                      let id = reference["id"] as? String else {
                    let missing = raw.isEmpty || raw[0] is NSNull
                    let hint = missing ? " models.getModelOfType() returns undefined for an unknown provider or id." : ""
                    throw CodemodeBridgeError.message("\(call.name)() expects \(article) model as its first argument, got \(describeValue(ordered.first)).\(hint) \(listHint)")
                }
                guard let resolved = models.getModelOfType(type, provider: providerName, modelId: id) else {
                    let actual = [ModelType.chat, .image, .classifier].first { $0 != type && models.getModelOfType($0, provider: providerName, modelId: id) != nil }
                    if let actual {
                        let actualArticle = actual == .image ? "an image" : "a \(actual.rawValue)"
                        throw CodemodeBridgeError.message("\"\(providerName)/\(id)\" is \(actualArticle) model, not \(article) model. \(listHint)")
                    }
                    throw CodemodeBridgeError.message("Unknown \(type.rawValue) model \"\(providerName)/\(id)\". \(listHint)")
                }
                let contextValue = ordered.count > 1 ? ordered[1] : nil
                let classifier = type == .classifier ? try classifierContext(contextValue) : nil
                let images = type == .image ? try imagesContext(contextValue) : nil
                let rowID = await state.nextModelCallID(call.name)
                let index = await state.start(id: rowID, name: call.name,
                                              args: "\(providerName)/\(id)")
                let started = Date()
                await limit.acquire()
                let reply: AnyCodable
                let stopReason: String
                let errorMessage: String?
                let usage: Usage?
                switch resolved {
                case .classifier(let model):
                    let result = await models.classify(model, context: classifier!, options: ClassifierOptions(signal: call.signal))
                    reply = classifierResult(result)
                    stopReason = result.stopReason.rawValue
                    errorMessage = result.errorMessage
                    usage = result.usage
                case .image(let model):
                    let result = await models.generateImages(model, context: images!, options: ImagesOptions(signal: call.signal))
                    await state.addGeneratedImages(result.output.filter { if case .image = $0 { return true }; return false }.count)
                    reply = imagesResult(result)
                    stopReason = result.stopReason.rawValue
                    errorMessage = result.errorMessage
                    usage = result.usage
                case .chat:
                    await limit.release()
                    throw CodemodeBridgeError.message("Invalid model type")
                }
                await limit.release()
                let status: CodemodeNestedCallStatus = stopReason == "stop" ? .ok : stopReason == "aborted" ? .cancelled : .error
                await state.finish(index: index, status: status,
                                   durationMs: Date().timeIntervalSince(started) * 1000,
                                   error: errorMessage, cost: usage?.cost.total, usage: usage)
                return success(reply)
            }
        default:
            throw CodemodeBridgeError.message("Unknown global \(call.name)")
        }
    } catch {
        return failure(error.localizedDescription)
    }
}

/// Execute one script and format its output for the model.
public func executeCodemode(toolCallId: String, params: [String: AnyCodable],
                            signal: CancellationToken? = nil, onUpdate: AgentToolUpdateCallback? = nil,
                            context: CustomToolContext? = nil,
                            options: CodemodeToolOptions = .init(),
                            forceWatchdog: Bool = false) async throws -> AgentToolResult {
    let started = Date()
    guard let code = params["code"]?.value as? String else {
        throw CodemodeBridgeError.message("codemode expects a code string")
    }
    let parsed = try parseCodemodeSource(code)
    let callable = context.map { getCodemodeCallableTools($0.tools) } ?? []
    let guidelines = options.getToolGuidelines?() ?? [:]
    let samples = Dictionary(uniqueKeysWithValues: callable.map {
        ($0.name, renderToolSample(CodemodeDeclaration(tool: $0, guidelines: guidelines[$0.name] ?? [])))
    })
    let runtimeTools = callable.map { CodemodeRuntimeTool(name: $0.name, description: samples[$0.name] ?? "") }
    let modelRuntime = options.modelRuntime ?? context?.modelRegistry
    var globals = [CodemodeRuntimeGlobal(name: "searchTools", spread: true),
                   CodemodeRuntimeGlobal(name: "describeTool", spread: true),
                   CodemodeRuntimeGlobal(name: "describeNamespace", spread: true)]
    if options.models && modelRuntime != nil {
        globals += ["models.getModelsOfType", "models.getAvailableOfType", "models.getModelOfType", "models.classify", "models.generateImages"]
            .map { CodemodeRuntimeGlobal(name: $0, spread: true) }
    }
    let state = CodemodeCallState(toolCallId: toolCallId, onUpdate: onUpdate)
    let limit = ClassifyLimit()
    let byName = Dictionary(uniqueKeysWithValues: callable.map { ($0.name, $0) })
    let result = await CodemodeSandbox.execute(
        code: parsed.code, tools: runtimeTools, globals: globals,
        store: context.map { readCodemodeStore($0.sessionManager.getBranch()) } ?? [:],
        timeoutMs: parsed.options.timeoutMs, signal: signal, forceWatchdog: forceWatchdog,
        onCall: { call in
            switch call.target {
            case .tool:
                return await handleTool(call, tool: byName[call.name], context: context, state: state)
            case .global:
                return await handleGlobal(call, callable: callable, samples: samples, options: options,
                                          modelRuntime: modelRuntime, state: state, limit: limit)
            }
        })
    let final = await state.complete()
    if result.execution.failure == nil,
       !result.storeWrites.set.isEmpty || !result.storeWrites.delete.isEmpty {
        options.appendEntry?(CODEMODE_STORE_ENTRY_TYPE, CodemodeStoreEntryData(
            set: result.storeWrites.set, delete: result.storeWrites.delete))
    }
    var execution = result.execution
    if result.usedWatchdog, var issue = execution.failure,
       issue.kind == .timeout || issue.kind == .aborted {
        issue.message += ". JavaScriptCore could not stop the sandbox thread; it may continue running"
        execution.failure = issue
    }
    let hasImage = execution.output.contains { if case .image = $0 { return true }; return false }
    let note = final.generatedImages > 0 && !hasImage
        ? "Note: models.generateImages() returned \(final.generatedImages) image\(final.generatedImages == 1 ? "" : "s") that the script did not show. Show each image block of result.output with image(block)." : nil
    return try formatCodemodeResultForExecution(execution, calls: final.calls,
                                wallTimeSeconds: Date().timeIntervalSince(started),
                                maxOutputTokens: parsed.options.maxOutputTokens ?? 10_000,
                                usage: final.usage, outputNote: note)
}
