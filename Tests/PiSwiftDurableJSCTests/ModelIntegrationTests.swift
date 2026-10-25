import Foundation
import Synchronization
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurable
import PiSwiftDurableJSC
import PiSwiftDurableTesting
import Testing

private let jscModelPNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
private let jscModelContext = "{state: {}, questions: {good: {type: 'bool', instructions: 'Is it good?', criteria: {true: 'yes', false: 'no'}}}}"
private let jscModelRef = "{provider: 'test', id: 'judge', headers: {authorization: 'evil'}, baseUrl: 'https://evil.invalid'}"
private let jscImageRef = "{provider: 'test', id: 'painter'}"
private let jscImageContext = "{input: [{type: 'text', text: 'a cat'}]}"

private final class JSCIntegrationModels: CodemodeModels {
    struct State: Sendable {
        var classify = 0, images = 0, inFlight = 0, maxInFlight = 0, catalog = 0, finished = 0
    }
    let chat: FakeDurableModels
    let state = Mutex(State())
    let gate = HarnessChatSignal(), atFour = HarnessChatSignal(), drained = HarnessChatSignal()
    let hold: Bool
    let classifier = ClassifierModel(id: "judge", name: "Judge", api: .typesafeSystemOne, provider: "test", baseUrl: "https://example.invalid", input: [.text], cost: .init(input: 0, output: 0, cacheRead: 0, cacheWrite: 0), contextWindow: 1000, headers: ["authorization": "secret"])
    let painter = ImageModel(id: "painter", name: "Painter", api: .openrouterImages, provider: "test", baseUrl: "https://example.invalid", input: [.text], output: [.image], cost: .init(input: 0, output: 0, cacheRead: 0, cacheWrite: 0))
    init(_ chat: FakeDurableModels, hold: Bool) { self.chat = chat; self.hold = hold }
    func getModel(provider: String, modelId: String) -> Model? { chat.getModel(provider: provider, modelId: modelId) }
    func streamSimple(model: Model, context: PiSwiftAI.Context, options: SimpleStreamOptions) -> AssistantMessageEventStream { chat.streamSimple(model: model, context: context, options: options) }
    func getModelsOfType(_ type: ModelType, provider: String?) -> [AnyModel] {
        state.withLock { $0.catalog += 1 }
        return ([AnyModel.classifier(classifier), .image(painter)] + chat.models.map(AnyModel.chat)).filter { $0.type == type && (provider == nil || $0.provider == provider) }
    }
    func getAvailableOfType(_ type: ModelType, provider: String?, context: ChordContext) async throws -> [AnyModel] {
        if hold { await atFour.wait() }
        return getModelsOfType(type, provider: provider)
    }
    private func begin(images: Bool) {
        let count = state.withLock { s in
            if images { s.images += 1 } else { s.classify += 1 }
            s.inFlight += 1; s.maxInFlight = max(s.maxInFlight, s.inFlight)
            return s.inFlight
        }
        if count == 4 { atFour.signal() }
    }
    private func finish() {
        let count = state.withLock { s in s.inFlight -= 1; s.finished += 1; return s.finished }
        if count == 4 { drained.signal() }
    }
    func classify(model: ClassifierModel, context: ClassifierContext, operation: ChordContext) async throws -> ClassifierResult {
        #expect(model.baseUrl == "https://example.invalid")
        #expect(model.headers?["authorization"] == "secret")
        begin(images: false)
        defer { finish() }
        if hold { try await awaitWithContext(Task { await self.gate.wait() }, operation) }
        if context.state["fail"]?.value as? Bool == true {
            return .init(api: model.api, provider: model.provider, model: model.id, stopReason: .error, errorMessage: "quota exceeded", timestamp: 0)
        }
        var usage = Usage(input: 10, output: 2, cacheRead: 0, cacheWrite: 0, totalTokens: 12)
        usage.cost = .init(input: 0.001, output: 0.0002, cacheRead: 0, cacheWrite: 0, total: 0.0012)
        return .init(api: model.api, provider: model.provider, model: model.id, answers: ["good": .bool(probability: 1)], usage: usage, timestamp: 0)
    }
    func generateImages(model: ImageModel, context: ImagesContext, operation: ChordContext) async throws -> AssistantImages {
        begin(images: true)
        defer { finish() }
        if hold { try await awaitWithContext(Task { await self.gate.wait() }, operation) }
        return .init(api: model.api, provider: model.provider, model: model.id, output: [.image(.init(data: jscModelPNG, mimeType: "image/png"))], stopReason: .stop, timestamp: 0)
    }
}

private func jscModelText(_ message: JSONValue) -> String {
    message["content"]?.arrayValue?.compactMap { $0["text"]?.stringValue }.joined() ?? ""
}

private func jscModelRun(_ code: String, forceWatchdog: Bool, hold: Bool = false, spillRelease: Bool = false,
    beforeWait: (@Sendable (JSCIntegrationModels) async -> Void)? = nil) async throws -> (JSONValue, JSCIntegrationModels, UsageState?) {
    let setup = HarnessChatSetup()
    let sandbox = JSCCodemodeSandbox(forceWatchdog: forceWatchdog)
    let models = JSCIntegrationModels(setup.models, hold: hold)
    try setup.registry.install(createCodemodeExtension(options: .init(sandbox: sandbox)))
    var call = chatAssistant("")
    call.content = [.toolCall(ToolCall(id: "jsc-models", name: "codemode", arguments: ["code": AnyCodable(code)]))]
    call.stopReason = .toolUse
    setup.models.setResponses([.message(call), .message(chatAssistant("done"))])
    let env: any ExecutionEnv = spillRelease ? JSCModelSpillEnv(base: FakeExecutionEnv(), models: models) : FakeExecutionEnv()
    let harness = try await Harness.open(storage: MemoryStorage(), options: .init(models: models, registry: setup.registry,
        settings: setup.settingsProvider, env: { _, _ in env }, onReport: { setup.reports.append($0) }), context: .background)
    do {
        let root = try await harness.root(options: .init(agent: .init(model: .set(.init(provider: "faux", modelId: "faux-1")))), context: .background)
        let submission = try await root.submit(.input(content: .text("go")), context: .background)
        if let beforeWait { await beforeWait(models) }
        #expect(try await submission.wait(context: .background).status == "done")
        try await harness.waitForIdle(context: .background)
        let message = try #require(try await allEntries(root).first { $0.kind == "pi.tool-result" }?.model?.first)
        let usage = try await harness.snapshot(UsageDoc, conversationId: root.id, context: .background)
        #expect(setup.reports.values.isEmpty)
        try await harness.close(context: .background)
        await sandbox.close()
        return (message, models, usage)
    } catch {
        models.gate.signal()
        try? await harness.close(context: .background)
        await sandbox.close()
        throw error
    }
}

@Suite(.timeLimit(.minutes(1)))
struct CodemodeModelIntegrationTests {
    @Test(arguments: [false, true])
    func catalogStripsCredentialHeaders(forceWatchdog: Bool) async throws {
        let (message, models, _) = try await jscModelRun("""
        const all = await models.getModelsOfType('classifier', 'test');
        const one = await models.getModelOfType('classifier', 'test', 'judge');
        const available = await models.getAvailableOfType('image');
        return [all.map(m => m.id), one.id, 'headers' in one, all.some(m => 'headers' in m), available.map(m => m.id)];
        """, forceWatchdog: forceWatchdog)
        #expect(jscModelText(message).contains("[[\"judge\"],\"judge\",false,false,[\"painter\"]]"))
        #expect(models.state.withLock { $0.catalog } == 3)
    }

    @Test(arguments: [false, true])
    func internalClassifierUsageAndHiddenListings(forceWatchdog: Bool) async throws {
        let (message, models, usage) = try await jscModelRun("""
        const result = await models.classify(\(jscModelRef), \(jscModelContext));
        return [result.stopReason, result.answers.good.probability,
          Object.keys(tools).some(n => n.includes('models')),
          ALL_TOOLS.some(t => t.name.includes('models')),
          (await searchTools('classify generate images models')).length,
          (await describeTool('pi.codemode.models.classify')) !== undefined];
        """, forceWatchdog: forceWatchdog)
        #expect(jscModelText(message).contains("[\"stop\",1,false,false,0,false]"))
        #expect(models.state.withLock { $0.classify } == 1)
        #expect(message["details"]?["calls"]?.arrayValue?.count == 1)
        #expect(message["details"]?["calls"]?[0]?["name"] == "models.classify")
        #expect(message["details"]?["calls"]?[0]?["status"] == "ok")
        #expect(abs((usage?.tools["pi.codemode.models.classify"]?.cost.total ?? 0) - 0.0012) < 0.000001)
        #expect(usage?.tools["pi.codemode.models.classify"]?.input == 10)
    }

    @Test(arguments: [false, true])
    func failedModelResolvesItsResult(forceWatchdog: Bool) async throws {
        let (message, models, _) = try await jscModelRun("""
        const context = \(jscModelContext); context.state.fail = true;
        const result = await models.classify(\(jscModelRef), context);
        return [result.stopReason, result.errorMessage];
        """, forceWatchdog: forceWatchdog)
        #expect(jscModelText(message).contains("[\"error\",\"quota exceeded\"]"))
        #expect(message["details"]?["calls"]?[0]?["status"] == "error")
        #expect(models.state.withLock { $0.classify } == 1)
    }

    @Test(arguments: [false, true])
    func invalidClassifierContextStopsBeforeRequest(forceWatchdog: Bool) async throws {
        let (message, models, _) = try await jscModelRun("""
        try { await models.classify(\(jscModelRef), {prompt: 'x'}); }
        catch (error) { return error.message; }
        """, forceWatchdog: forceWatchdog)
        #expect(jscModelText(message).contains("context.state must be an object"))
        #expect(jscModelText(message).contains("Expected context:"))
        #expect(models.state.withLock { $0.classify } == 0)
    }

    @Test(arguments: [false, true], ["classifier", "image", "mixed"])
    func atMostFourModelCalls(forceWatchdog: Bool, kind: String) async throws {
        let (message, models, _) = try await jscModelRun("""
        const classify = () => models.classify(\(jscModelRef), \(jscModelContext));
        const images = () => models.generateImages(\(jscImageRef), \(jscImageContext));
        return (await Promise.all(Array.from({length: 8}, (_, i) =>
          '\(kind)' === 'classifier' ? classify() : '\(kind)' === 'image' ? images() : i % 2 ? images() : classify()))).length;
        """, forceWatchdog: forceWatchdog, hold: true, beforeWait: { models in
            await models.atFour.wait()
            // Keep the first four requests active while the other calls wait for a slot.
            try? await Task.sleep(for: .milliseconds(50))
            #expect(models.state.withLock { $0.inFlight } == 4)
            #expect(models.state.withLock { $0.classify + $0.images } == 4)
            models.gate.signal()
        })
        #expect(jscModelText(message).contains("Output:\n8"))
        let state = models.state.withLock { $0 }
        #expect(state.classify == (kind == "classifier" ? 8 : kind == "mixed" ? 4 : 0))
        #expect(state.images == (kind == "image" ? 8 : kind == "mixed" ? 4 : 0))
        #expect(state.maxInFlight == 4)
    }

    @Test(arguments: [false, true])
    func queuedModelsDoNotStartAfterCompletion(forceWatchdog: Bool) async throws {
        let (message, models, _) = try await jscModelRun("""
        for (let i = 0; i < 6; i++) models.classify(\(jscModelRef), \(jscModelContext)).catch(() => {});
        await models.getAvailableOfType('image');
        return 'x'.repeat(60000);
        """, forceWatchdog: forceWatchdog, hold: true, spillRelease: true)
        #expect(jscModelText(message).contains("[Full output: "))
        #expect(models.state.withLock { $0.classify } == 4)
    }

    @Test(arguments: [false, true], [false, true])
    func generatedImagesNoteAndShownImages(forceWatchdog: Bool, show: Bool) async throws {
        let (message, models, _) = try await jscModelRun("""
        const result = await models.generateImages(\(jscImageRef), \(jscImageContext));
        \(show ? "image(result.output[0]);" : "return result.output.length;")
        """, forceWatchdog: forceWatchdog)
        #expect(models.state.withLock { $0.images } == 1)
        #expect(jscModelText(message).contains("Note: models.generateImages() returned 1 image") == !show)
        #expect(message["content"]?.arrayValue?.contains { $0["type"] == "image" } == show)
    }
}

private struct JSCModelSpillEnv: ExecutionEnv {
    let base: FakeExecutionEnv
    let models: JSCIntegrationModels
    var id: String { base.id }
    var cwd: String { get { base.cwd } nonmutating set { base.cwd = newValue } }
    func absolutePath(_ path: String, context: ChordContext) async -> Result<String, FileError> { await base.absolutePath(path, context: context) }
    func joinPath(_ parts: [String], context: ChordContext) async -> Result<String, FileError> { await base.joinPath(parts, context: context) }
    func readTextFile(_ path: String, context: ChordContext) async -> Result<String, FileError> { await base.readTextFile(path, context: context) }
    func openTextLineReader(_ path: String, context: ChordContext) async -> Result<any TextLineReader, FileError> { await base.openTextLineReader(path, context: context) }
    func readTextLines(_ path: String, options: ReadTextLinesOptions?, context: ChordContext) async -> Result<[String], FileError> { await base.readTextLines(path, options: options, context: context) }
    func readBinaryFile(_ path: String, context: ChordContext) async -> Result<[UInt8], FileError> { await base.readBinaryFile(path, context: context) }
    func openBinaryReader(_ path: String, options: OpenBinaryReaderOptions?, context: ChordContext) async -> Result<any BinaryReader, FileError> { await base.openBinaryReader(path, options: options, context: context) }
    func writeFile(_ path: String, content: FileContent, context: ChordContext) async -> Result<Void, FileError> { await base.writeFile(path, content: content, context: context) }
    func appendFile(_ path: String, content: FileContent, context: ChordContext) async -> Result<Void, FileError> { await base.appendFile(path, content: content, context: context) }
    func truncateFile(_ path: String, size: Int64, context: ChordContext) async -> Result<Void, FileError> { await base.truncateFile(path, size: size, context: context) }
    func flushFile(_ path: String, context: ChordContext) async -> Result<Void, FileError> { await base.flushFile(path, context: context) }
    func renameFile(_ sourcePath: String, destinationPath: String, context: ChordContext) async -> Result<Void, FileError> { await base.renameFile(sourcePath, destinationPath: destinationPath, context: context) }
    func fileInfo(_ path: String, context: ChordContext) async -> Result<FileInfo, FileError> { await base.fileInfo(path, context: context) }
    func listDir(_ path: String, context: ChordContext) async -> Result<[FileInfo], FileError> { await base.listDir(path, context: context) }
    func listFiles(_ path: String, options: ListFilesOptions?, context: ChordContext) async -> Result<FileListing, FileError> { await base.listFiles(path, options: options, context: context) }
    func openDirReader(_ path: String, context: ChordContext) async -> Result<any DirReader, FileError> { await base.openDirReader(path, context: context) }
    func watch(_ targets: [WatchTarget], onChange: @escaping @Sendable (WatchChange) -> Void, context: ChordContext) async -> Result<any FileWatcher, FileError> { await base.watch(targets, onChange: onChange, context: context) }
    func canonicalPath(_ path: String, context: ChordContext) async -> Result<String, FileError> { await base.canonicalPath(path, context: context) }
    func exists(_ path: String, context: ChordContext) async -> Result<Bool, FileError> { await base.exists(path, context: context) }
    func createDir(_ path: String, options: CreateDirOptions?, context: ChordContext) async -> Result<Void, FileError> { await base.createDir(path, options: options, context: context) }
    func remove(_ path: String, options: RemoveOptions?, context: ChordContext) async -> Result<Void, FileError> { await base.remove(path, options: options, context: context) }
    func createTempDir(prefix: String?, context: ChordContext) async -> Result<String, FileError> {
        // The script has completed. Release the four active requests before the output is stored.
        models.gate.signal()
        await models.drained.wait()
        return await base.createTempDir(prefix: prefix, context: context)
    }
    func createTempFile(options: CreateTempFileOptions?, context: ChordContext) async -> Result<String, FileError> { await base.createTempFile(options: options, context: context) }
    func cleanup(context: ChordContext) async { await base.cleanup(context: context) }
    func exec(_ command: ShellCommand, options: ShellExecOptions?, context: ChordContext) async -> Result<ShellExecResult, ExecutionError> { await base.exec(command, options: options, context: context) }
}

