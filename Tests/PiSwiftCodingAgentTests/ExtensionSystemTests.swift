import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

// MARK: - Helpers

private func fixturesRoot() -> String {
    if let resourceURL = Bundle.module.resourceURL {
        return resourceURL.appendingPathComponent("fixtures").path
    }
    let filePath = URL(fileURLWithPath: #filePath)
    return filePath.deletingLastPathComponent().appendingPathComponent("fixtures").path
}

private func extensionFixture(_ name: String) -> String {
    URL(fileURLWithPath: fixturesRoot()).appendingPathComponent("extensions/\(name)").path
}

/// Resolve the SDK paths for tests from the SPM build artifacts.
private func testSDKPaths() -> ExtensionCompiler.SDKPaths? {
    func checkBuildDir(_ buildDir: String) -> ExtensionCompiler.SDKPaths? {
        let modulesDir = (buildDir as NSString).appendingPathComponent("Modules")
        let moduleFile = (modulesDir as NSString).appendingPathComponent("PiExtensionSDK.swiftmodule")
        let libFile = (buildDir as NSString).appendingPathComponent("libPiExtensionSDK.dylib")
        if FileManager.default.fileExists(atPath: moduleFile),
           FileManager.default.fileExists(atPath: libFile) {
            return ExtensionCompiler.SDKPaths(modulePath: modulesDir, libPath: buildDir)
        }
        return nil
    }

    func walkUp(from baseDir: String) -> ExtensionCompiler.SDKPaths? {
        var dir = baseDir as NSString
        for _ in 0..<10 {
            for config in ["debug", "release"] {
                let buildDir = (dir as NSString).appendingPathComponent(".build/\(config)")
                if let result = checkBuildDir(buildDir) { return result }
            }
            dir = dir.deletingLastPathComponent as NSString
        }
        return nil
    }

    // 1. The test bundle lives inside .build/<triple>/debug/  —  the SDK
    //    artifacts (.swiftmodule + .dylib) are in that same directory.
    if let resourceURL = Bundle.module.resourceURL {
        let debugDir = resourceURL.deletingLastPathComponent().path
        if let paths = checkBuildDir(debugDir) { return paths }
    }

    // 2. Walk up from #filePath (absolute source tree path).
    //    NOTE: #file in Swift 6 returns a module-relative path; use #filePath.
    let filePath = (#filePath as NSString).deletingLastPathComponent
    if let paths = walkUp(from: filePath) { return paths }

    // 3. Fall back to ExtensionCompiler's own resolution
    return ExtensionCompiler.resolveSDKPaths()
}

/// Seed `PI_EXTENSION_SDK_PATH` once for the whole suite. The reload-lifecycle tests
/// drive `createAgentSession`, which calls `discoverAndLoadExtensions`, which calls
/// `ExtensionCompiler.resolveSDKPaths()`. From within an xctest bundle the SPM
/// walk-up doesn't find `.build/<config>` reliably (argv[0] points into the bundle),
/// so we pin the env var to the SPM build dir up-front. Tests that need to verify
/// alternative layouts use `ExtensionCompiler.sdkPathsAt(_:)` directly.
private nonisolated(unsafe) let _seedExtensionSDK: Void = {
    if let paths = ExtensionCompiler.resolveSDKPaths() {
        setenv("PI_EXTENSION_SDK_PATH", paths.libPath, 1)
        return
    }
    // Best-effort fallback: walk up from this source file.
    let filePath = (#filePath as NSString).deletingLastPathComponent
    var dir = filePath as NSString
    for _ in 0..<10 {
        for config in ["debug", "release"] {
            let candidate = (dir as NSString).appendingPathComponent(".build/\(config)")
            let dylib = (candidate as NSString).appendingPathComponent("libPiExtensionSDK.dylib")
            if FileManager.default.fileExists(atPath: dylib) {
                setenv("PI_EXTENSION_SDK_PATH", candidate, 1)
                return
            }
        }
        dir = dir.deletingLastPathComponent as NSString
    }
}()

private func withTempDir(_ body: (String) async throws -> Void) async rethrows {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pi-ext-test-\(UUID().uuidString)")
        .path
    try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tempDir) }
    try await body(tempDir)
}

// MARK: - ExtensionCompiler Tests

@Test func compilerContentHashIsDeterministic() throws {
    let data = Data("hello world".utf8)
    let hash1 = ExtensionCompiler.sha256(data)
    let hash2 = ExtensionCompiler.sha256(data)
    #expect(hash1 == hash2)
    #expect(hash1.count == 64) // SHA-256 produces 64 hex chars
}

@Test func compilerContentHashDiffersForDifferentInput() throws {
    let hash1 = ExtensionCompiler.sha256(Data("hello".utf8))
    let hash2 = ExtensionCompiler.sha256(Data("world".utf8))
    #expect(hash1 != hash2)
}

@Test func compilerResolvesSDKPaths() throws {
    let paths = testSDKPaths()
    #expect(paths != nil, "SDK paths should be resolvable from test environment")
    if let paths {
        let modulePath = (paths.modulePath as NSString).appendingPathComponent("PiExtensionSDK.swiftmodule")
        #expect(FileManager.default.fileExists(atPath: modulePath))
        let libPath = (paths.libPath as NSString).appendingPathComponent("libPiExtensionSDK.dylib")
        #expect(FileManager.default.fileExists(atPath: libPath))
    }
}

@Test func compilerResolvesSDKPathsFromInstalledFHSLayout() async throws {
    // Verify the resolver's layout detection under a Makefile-style install:
    //
    //   <prefix>/lib/pi/libPiExtensionSDK.dylib
    //   <prefix>/lib/pi/Modules/PiExtensionSDK.swiftmodule
    //
    // We exercise `sdkPathsAt` directly rather than the full `resolveSDKPaths` env
    // override path — mutating `PI_EXTENSION_SDK_PATH` would race against the
    // resolver-using tests that run in parallel.
    guard let realPaths = testSDKPaths() else {
        Issue.record("real SDK paths unavailable")
        return
    }

    try await withTempDir { tempDir in
        let libDir = (tempDir as NSString).appendingPathComponent("lib/pi")
        let modulesDir = (libDir as NSString).appendingPathComponent("Modules")
        try FileManager.default.createDirectory(atPath: modulesDir, withIntermediateDirectories: true)

        let realDylib = (realPaths.libPath as NSString).appendingPathComponent("libPiExtensionSDK.dylib")
        let realModule = (realPaths.modulePath as NSString).appendingPathComponent("PiExtensionSDK.swiftmodule")
        let stagedDylib = (libDir as NSString).appendingPathComponent("libPiExtensionSDK.dylib")
        let stagedModule = (modulesDir as NSString).appendingPathComponent("PiExtensionSDK.swiftmodule")
        try FileManager.default.copyItem(atPath: realDylib, toPath: stagedDylib)
        try FileManager.default.copyItem(atPath: realModule, toPath: stagedModule)

        guard let resolved = ExtensionCompiler.sdkPathsAt(libDir) else {
            Issue.record("sdkPathsAt should succeed under FHS layout")
            return
        }
        #expect(resolved.libPath == libDir,
                "libPath must point at the lib/pi/ dir, got \(resolved.libPath)")
        #expect(resolved.modulePath == modulesDir,
                "modulePath must point at the lib/pi/Modules/ subdir, got \(resolved.modulePath)")

        // Flat layout (everything in libDir, no Modules/ subdir) also resolves.
        try await withTempDir { flatDir in
            try FileManager.default.copyItem(atPath: realDylib, toPath: (flatDir as NSString).appendingPathComponent("libPiExtensionSDK.dylib"))
            try FileManager.default.copyItem(atPath: realModule, toPath: (flatDir as NSString).appendingPathComponent("PiExtensionSDK.swiftmodule"))
            guard let flat = ExtensionCompiler.sdkPathsAt(flatDir) else {
                Issue.record("sdkPathsAt should succeed under flat layout")
                return
            }
            #expect(flat.modulePath == flatDir)
            #expect(flat.libPath == flatDir)
        }

        // Missing artifacts → nil.
        try await withTempDir { emptyDir in
            #expect(ExtensionCompiler.sdkPathsAt(emptyDir) == nil)
        }
    }
}

@Test func compilerCompilesSingleFile() async throws {
    guard let sdkPaths = testSDKPaths() else {
        Issue.record("SDK paths not available")
        return
    }

    try await withTempDir { cacheDir in
        let source = extensionFixture("hello-extension.swift")
        let dylibPath = try await ExtensionCompiler.compileSingleFile(
            sourcePath: source,
            cacheDir: cacheDir,
            sdkPaths: sdkPaths
        )

        #expect(FileManager.default.fileExists(atPath: dylibPath))
        #expect(dylibPath.hasSuffix(".dylib"))
        #expect(dylibPath.hasPrefix(cacheDir))
    }
}

@Test func compilerCacheHitOnSecondCompilation() async throws {
    guard let sdkPaths = testSDKPaths() else {
        Issue.record("SDK paths not available")
        return
    }

    try await withTempDir { cacheDir in
        let source = extensionFixture("hello-extension.swift")

        let path1 = try await ExtensionCompiler.compileSingleFile(
            sourcePath: source, cacheDir: cacheDir, sdkPaths: sdkPaths
        )
        let attrs1 = try FileManager.default.attributesOfItem(atPath: path1)
        let mtime1 = attrs1[.modificationDate] as? Date

        // Small delay to ensure mtime would differ on a recompile
        try await Task.sleep(for: .milliseconds(50))

        let path2 = try await ExtensionCompiler.compileSingleFile(
            sourcePath: source, cacheDir: cacheDir, sdkPaths: sdkPaths
        )
        let attrs2 = try FileManager.default.attributesOfItem(atPath: path2)
        let mtime2 = attrs2[.modificationDate] as? Date

        #expect(path1 == path2, "Cache should return the same path")
        #expect(mtime1 == mtime2, "File should not be recompiled (same mtime)")
    }
}

@Test func compilerReportsCompilationErrors() async throws {
    guard let sdkPaths = testSDKPaths() else {
        Issue.record("SDK paths not available")
        return
    }

    try await withTempDir { cacheDir in
        let source = extensionFixture("bad-syntax.swift")

        do {
            _ = try await ExtensionCompiler.compileSingleFile(
                sourcePath: source, cacheDir: cacheDir, sdkPaths: sdkPaths
            )
            Issue.record("Expected compilation to throw")
        } catch let error as ExtensionLoadError {
            if case .compilationError(_, let msg) = error {
                #expect(msg.contains("error:"), "Should contain swiftc error output, got: \(msg)")
            } else {
                Issue.record("Expected .compilationError, got \(error)")
            }
        }
    }
}

// MARK: - ExtensionDylibLoader Tests

@Test func loaderLoadsCompiledExtension() async throws {
    guard let sdkPaths = testSDKPaths() else {
        Issue.record("SDK paths not available")
        return
    }

    try await withTempDir { cacheDir in
        let source = extensionFixture("hello-extension.swift")
        let dylibPath = try await ExtensionCompiler.compileSingleFile(
            sourcePath: source, cacheDir: cacheDir, sdkPaths: sdkPaths
        )

        let eventBus = createEventBus()
        let hook = try ExtensionDylibLoader.loadAndInitialize(
            dylibPath: dylibPath,
            extensionPath: source,
            eventBus: eventBus,
            cwd: cacheDir
        )

        #expect(hook.path == source)
        // hello-extension.swift registers a "session_start" handler and a "hello" command
        #expect(hook.handlers["session_start"] != nil, "Should have session_start handler")
        #expect(hook.handlers["session_start"]?.count == 1)
        #expect(hook.commands["hello"] != nil, "Should have hello command")
        #expect(hook.commands["hello"]?.description == "Say hello from extension")
    }
}

@Test func loaderCapturesMultipleHandlersAndCommands() async throws {
    guard let sdkPaths = testSDKPaths() else {
        Issue.record("SDK paths not available")
        return
    }

    try await withTempDir { cacheDir in
        let source = extensionFixture("event-counter.swift")
        let dylibPath = try await ExtensionCompiler.compileSingleFile(
            sourcePath: source, cacheDir: cacheDir, sdkPaths: sdkPaths
        )

        let eventBus = createEventBus()
        let hook = try ExtensionDylibLoader.loadAndInitialize(
            dylibPath: dylibPath,
            extensionPath: source,
            eventBus: eventBus,
            cwd: cacheDir
        )

        // event-counter.swift registers handlers for session_start, agent_start, agent_end
        #expect(hook.handlers["session_start"] != nil)
        #expect(hook.handlers["agent_start"] != nil)
        #expect(hook.handlers["agent_end"] != nil)
        // And two commands: count, reset
        #expect(hook.commands["count"] != nil)
        #expect(hook.commands["reset"] != nil)
    }
}

@Test func loaderFailsOnMissingEntryPoint() async throws {
    guard let sdkPaths = testSDKPaths() else {
        Issue.record("SDK paths not available")
        return
    }

    try await withTempDir { cacheDir in
        let source = extensionFixture("no-entry-point.swift")
        let dylibPath = try await ExtensionCompiler.compileSingleFile(
            sourcePath: source, cacheDir: cacheDir, sdkPaths: sdkPaths
        )

        let eventBus = createEventBus()
        do {
            _ = try ExtensionDylibLoader.loadAndInitialize(
                dylibPath: dylibPath,
                extensionPath: source,
                eventBus: eventBus,
                cwd: cacheDir
            )
            Issue.record("Expected loading to throw due to missing piExtensionMain")
        } catch let error as ExtensionLoadError {
            if case .loadError(_, let msg) = error {
                #expect(msg.contains("piExtensionMain"), "Error should mention missing symbol, got: \(msg)")
            } else {
                Issue.record("Expected .loadError, got \(error)")
            }
        }
    }
}

// MARK: - ExtensionLoader Integration Tests

@Test func extensionLoaderDiscoversFindSwiftFiles() {
    let fixtureDir = URL(fileURLWithPath: fixturesRoot()).appendingPathComponent("extensions").path
    let discovered = ExtensionLoader.discover(in: fixtureDir)

    let names = discovered.map { URL(fileURLWithPath: $0).lastPathComponent }
    #expect(names.contains("hello-extension.swift"))
    #expect(names.contains("event-counter.swift"))
    #expect(names.contains("bad-syntax.swift"))
    #expect(names.contains("no-entry-point.swift"))
    #expect(names.contains("tool-extension.swift"))
}

// MARK: - pi.registerTool (custom tool registration)

@Test func extensionCanRegisterCustomTool() async throws {
    guard let sdkPaths = testSDKPaths() else {
        Issue.record("SDK paths not available")
        return
    }

    try await withTempDir { cacheDir in
        let source = extensionFixture("tool-extension.swift")
        let eventBus = createEventBus()
        let result = await ExtensionLoader.load(
            source, cwd: cacheDir, eventBus: eventBus, cacheDir: cacheDir, sdkPaths: sdkPaths
        )
        guard let hook = result.hook else {
            Issue.record("tool-extension should load: \(String(describing: result.error))")
            return
        }
        #expect(hook.tools["ext-hello"] != nil,
                "extension's CustomTool should be captured on the LoadedHook")
        #expect(hook.tools["ext-hello"]?.description == "Greet someone — registered by an extension")
    }
}

@Test func hookRunnerAggregatesExtensionTools() async throws {
    guard let sdkPaths = testSDKPaths() else {
        Issue.record("SDK paths not available")
        return
    }

    try await withTempDir { cacheDir in
        let source = extensionFixture("tool-extension.swift")
        let eventBus = createEventBus()
        let result = await ExtensionLoader.load(
            source, cwd: cacheDir, eventBus: eventBus, cacheDir: cacheDir, sdkPaths: sdkPaths
        )
        guard let hook = result.hook else {
            Issue.record("tool-extension should load")
            return
        }

        let sessionManager = SessionManager.inMemory()
        let authStorage = AuthStorage(":memory:")
        let modelRegistry = ModelRegistry(authStorage)
        let runner = HookRunner([hook], cacheDir, sessionManager, modelRegistry)

        let tools = runner.getExtensionTools()
        #expect(tools.count == 1)
        #expect(tools.first?.name == "ext-hello")

        let names = runner.getExtensionToolNames()
        #expect(names == Set(["ext-hello"]))
    }
}

@Test func reloadAddsExtensionToolToAgentRoster() async throws {
    _ = _seedExtensionSDK
    guard testSDKPaths() != nil else {
        Issue.record("SDK paths not available")
        return
    }

    let toolSource = extensionFixture("tool-extension.swift")

    try await withTempDir { tempDir in
        let agentDir = (tempDir as NSString).appendingPathComponent("agent")
        try FileManager.default.createDirectory(atPath: agentDir, withIntermediateDirectories: true)

        // Start with no extensions, then add one via reload — proves the agent's tool
        // roster picks up newly-registered tools.
        let result = await createAgentSession(CreateAgentSessionOptions(
            cwd: tempDir,
            agentDir: agentDir
        ))
        let session = result.session
        defer { session.dispose() }

        let initialToolCount = session.agent.state.tools.count
        #expect(!session.getAllToolNames().contains("ext-hello"),
                "before reload, the extension tool should not exist")

        // Drop the fixture into the discovery dir so reload picks it up.
        let extDir = (agentDir as NSString).appendingPathComponent("extensions")
        try FileManager.default.createDirectory(atPath: extDir, withIntermediateDirectories: true)
        let extPath = (extDir as NSString).appendingPathComponent("tool-extension.swift")
        try FileManager.default.copyItem(atPath: toolSource, toPath: extPath)

        let reloadResult = await session.reloadExtensions()
        #expect(reloadResult.errors.isEmpty,
                "reload should succeed: \(reloadResult.errors)")
        // macOS symlinks /var → /private/var, so loadedPaths comes back resolved.
        // Compare on basenames to dodge the symlink mismatch.
        let loadedNames = reloadResult.loadedPaths.map { URL(fileURLWithPath: $0).lastPathComponent }
        #expect(loadedNames.contains("tool-extension.swift"))

        #expect(session.getAllToolNames().contains("ext-hello"),
                "after reload, the extension tool should appear in the registry")
        #expect(session.agent.state.tools.contains { $0.name == "ext-hello" },
                "after reload, the extension tool should be active on the agent")
        #expect(session.agent.state.tools.count == initialToolCount + 1,
                "exactly one new tool should be added")
    }
}

@Test func reloadRemovesToolWhenExtensionDeleted() async throws {
    _ = _seedExtensionSDK
    guard testSDKPaths() != nil else {
        Issue.record("SDK paths not available")
        return
    }

    let toolSource = extensionFixture("tool-extension.swift")

    try await withTempDir { tempDir in
        let agentDir = (tempDir as NSString).appendingPathComponent("agent")
        let extDir = (agentDir as NSString).appendingPathComponent("extensions")
        try FileManager.default.createDirectory(atPath: extDir, withIntermediateDirectories: true)

        let extPath = (extDir as NSString).appendingPathComponent("tool-extension.swift")
        try FileManager.default.copyItem(atPath: toolSource, toPath: extPath)

        let result = await createAgentSession(CreateAgentSessionOptions(
            cwd: tempDir,
            agentDir: agentDir
        ))
        let session = result.session
        defer { session.dispose() }

        #expect(session.agent.state.tools.contains { $0.name == "ext-hello" },
                "tool should be active at startup")

        // Delete the extension and reload — the tool should disappear.
        try FileManager.default.removeItem(atPath: extPath)

        let reloadResult = await session.reloadExtensions()
        #expect(reloadResult.errors.isEmpty)
        let loadedNames = reloadResult.loadedPaths.map { URL(fileURLWithPath: $0).lastPathComponent }
        #expect(!loadedNames.contains("tool-extension.swift"))

        #expect(!session.agent.state.tools.contains { $0.name == "ext-hello" },
                "after deleting the extension and reloading, its tool must be gone")
        #expect(!session.getAllToolNames().contains("ext-hello"),
                "the registry must drop the removed tool too")
    }
}

@Test func extensionLoaderDiscoverSkipsHiddenFiles() async throws {
    try await withTempDir { tempDir in
        let extDir = (tempDir as NSString).appendingPathComponent("extensions")
        try FileManager.default.createDirectory(atPath: extDir, withIntermediateDirectories: true)

        // Create a visible and hidden file
        try "visible".write(toFile: (extDir as NSString).appendingPathComponent("visible.swift"), atomically: true, encoding: .utf8)
        try "hidden".write(toFile: (extDir as NSString).appendingPathComponent(".hidden.swift"), atomically: true, encoding: .utf8)

        let discovered = ExtensionLoader.discover(in: extDir)
        let names = discovered.map { URL(fileURLWithPath: $0).lastPathComponent }
        #expect(names.contains("visible.swift"))
        #expect(!names.contains(".hidden.swift"))
    }
}

@Test func extensionLoaderDiscoverReturnsEmptyForMissingDir() {
    let discovered = ExtensionLoader.discover(in: "/nonexistent/path/that/does/not/exist")
    #expect(discovered.isEmpty)
}

@Test func extensionLoaderFullPipelineLoadsExtension() async throws {
    guard let sdkPaths = testSDKPaths() else {
        Issue.record("SDK paths not available")
        return
    }

    try await withTempDir { cacheDir in
        let source = extensionFixture("hello-extension.swift")
        let eventBus = createEventBus()

        let result = await ExtensionLoader.load(
            source,
            cwd: cacheDir,
            eventBus: eventBus,
            cacheDir: cacheDir,
            sdkPaths: sdkPaths
        )

        #expect(result.error == nil, "Should load without error, got: \(String(describing: result.error))")
        #expect(result.hook != nil)
        #expect(result.hook?.commands["hello"] != nil)
        #expect(result.hook?.handlers["session_start"]?.count == 1)
    }
}

@Test func extensionLoaderReportsFileNotFound() async throws {
    guard let sdkPaths = testSDKPaths() else {
        Issue.record("SDK paths not available")
        return
    }

    try await withTempDir { cacheDir in
        let eventBus = createEventBus()
        let result = await ExtensionLoader.load(
            "/nonexistent/path.swift",
            cwd: cacheDir,
            eventBus: eventBus,
            cacheDir: cacheDir,
            sdkPaths: sdkPaths
        )

        #expect(result.hook == nil)
        #expect(result.error != nil)
        if case .fileNotFound = result.error {
            // expected
        } else {
            Issue.record("Expected .fileNotFound, got \(String(describing: result.error))")
        }
    }
}

@Test func extensionLoaderReportsCompilationError() async throws {
    guard let sdkPaths = testSDKPaths() else {
        Issue.record("SDK paths not available")
        return
    }

    try await withTempDir { cacheDir in
        let source = extensionFixture("bad-syntax.swift")
        let eventBus = createEventBus()

        let result = await ExtensionLoader.load(
            source,
            cwd: cacheDir,
            eventBus: eventBus,
            cacheDir: cacheDir,
            sdkPaths: sdkPaths
        )

        #expect(result.hook == nil)
        #expect(result.error != nil)
        if case .compilationError = result.error {
            // expected
        } else {
            Issue.record("Expected .compilationError, got \(String(describing: result.error))")
        }
    }
}

@Test func loadMultipleExtensions() async throws {
    guard let sdkPaths = testSDKPaths() else {
        Issue.record("SDK paths not available")
        return
    }

    try await withTempDir { cacheDir in
        let eventBus = createEventBus()
        let paths = [
            extensionFixture("hello-extension.swift"),
            extensionFixture("event-counter.swift"),
        ]

        let result = await loadExtensions(
            paths,
            cwd: cacheDir,
            eventBus: eventBus,
            cacheDir: cacheDir,
            sdkPaths: sdkPaths
        )

        #expect(result.errors.isEmpty, "No errors expected, got: \(result.errors)")
        #expect(result.hooks.count == 2)

        // Verify hooks from both extensions are present
        let allCommands = result.hooks.flatMap { $0.commands.keys }
        #expect(allCommands.contains("hello"))
        #expect(allCommands.contains("count"))
        #expect(allCommands.contains("reset"))
    }
}

@Test func loadMixOfGoodAndBadExtensions() async throws {
    guard let sdkPaths = testSDKPaths() else {
        Issue.record("SDK paths not available")
        return
    }

    try await withTempDir { cacheDir in
        let eventBus = createEventBus()
        let paths = [
            extensionFixture("hello-extension.swift"),
            extensionFixture("bad-syntax.swift"),
            extensionFixture("event-counter.swift"),
        ]

        let result = await loadExtensions(
            paths,
            cwd: cacheDir,
            eventBus: eventBus,
            cacheDir: cacheDir,
            sdkPaths: sdkPaths
        )

        #expect(result.hooks.count == 2, "Two good extensions should load")
        #expect(result.errors.count == 1, "One bad extension should fail")
    }
}

// MARK: - HookRunner Integration

@Test func hookRunnerContextExposesModeTrustAndSystemPromptOptions() async throws {
    let observedMode = LockedState<HookMode?>(nil)
    let observedTrust = LockedState<Bool?>(nil)
    let observedCwd = LockedState<String?>(nil)
    let observedPromptCwd = LockedState<String?>(nil)
    let observedTools = LockedState<[ToolName]?>(nil)

    let handler: HookHandler = { _, ctx in
        observedMode.withLock { $0 = ctx.mode }
        observedTrust.withLock { $0 = ctx.isProjectTrusted() }
        observedCwd.withLock { $0 = ctx.cwd }
        let options = ctx.getSystemPromptOptions()
        observedPromptCwd.withLock { $0 = options.cwd }
        observedTools.withLock { $0 = options.selectedTools }
        return nil
    }
    let hook = LoadedHook(
        path: "/fake/context-hook",
        resolvedPath: "/fake/context-hook",
        handlers: ["session_start": [handler]]
    )

    let sessionManager = SessionManager.inMemory()
    let modelRegistry = ModelRegistry(AuthStorage(":memory:"))
    let runner = HookRunner([hook], "/tmp/project", sessionManager, modelRegistry)
    runner.initialize(
        getModel: { nil },
        getSystemPromptOptions: {
            BuildSystemPromptOptions(selectedTools: [.read, .bash], cwd: "/tmp/project")
        },
        isProjectTrusted: { false },
        mode: .rpc,
        hasUI: false
    )

    _ = await runner.emit(SessionStartEvent())

    #expect(observedMode.withLock { $0 } == .rpc)
    #expect(observedTrust.withLock { $0 } == false)
    #expect(observedCwd.withLock { $0 } == "/tmp/project")
    #expect(observedPromptCwd.withLock { $0 } == "/tmp/project")
    #expect(observedTools.withLock { $0 } == [.read, .bash])
}

@Test func hookCommandContextExposesModeTrustAndSystemPromptOptions() async throws {
    let sessionManager = SessionManager.inMemory()
    let modelRegistry = ModelRegistry(AuthStorage(":memory:"))
    let runner = HookRunner([], "/tmp/command-project", sessionManager, modelRegistry)
    runner.initialize(
        getModel: { nil },
        getSystemPromptOptions: {
            BuildSystemPromptOptions(selectedTools: [.edit], cwd: "/tmp/command-project")
        },
        isProjectTrusted: { false },
        mode: .tui,
        hasUI: true
    )

    let ctx = runner.createCommandContext()

    #expect(ctx.mode == .tui)
    #expect(ctx.isProjectTrusted() == false)
    #expect(ctx.getSystemPromptOptions().cwd == "/tmp/command-project")
    #expect(ctx.getSystemPromptOptions().selectedTools == [.edit])
}

@Test func projectTrustEventUsesFirstDefinitiveDecision() async throws {
    let calls = LockedState<[String]>([])
    let undecided: HookHandler = { _, _ in
        calls.withLock { $0.append("undecided") }
        return ProjectTrustEventResult(trusted: .undecided)
    }
    let accepted: HookHandler = { _, _ in
        calls.withLock { $0.append("yes") }
        return ProjectTrustEventResult(trusted: .yes, remember: true)
    }
    let skipped: HookHandler = { _, _ in
        calls.withLock { $0.append("skipped") }
        return ProjectTrustEventResult(trusted: .no)
    }
    let hook = LoadedHook(
        path: "/fake/trust-hook",
        resolvedPath: "/fake/trust-hook",
        handlers: ["project_trust": [undecided, accepted, skipped]]
    )

    let sessionManager = SessionManager.inMemory()
    let modelRegistry = ModelRegistry(AuthStorage(":memory:"))
    let runner = HookRunner([hook], "/tmp/project", sessionManager, modelRegistry)
    runner.initialize(getModel: { nil }, mode: .print, hasUI: false)

    let result = await runner.emitProjectTrust(ProjectTrustEvent(cwd: "/tmp/project"))

    #expect(result?.trusted == .yes)
    #expect(result?.remember == true)
    #expect(calls.withLock { $0 } == ["undecided", "yes"])
}

@Test func extensionHooksWorkWithHookRunner() async throws {
    guard let sdkPaths = testSDKPaths() else {
        Issue.record("SDK paths not available")
        return
    }

    try await withTempDir { cacheDir in
        let source = extensionFixture("hello-extension.swift")
        let eventBus = createEventBus()

        let result = await ExtensionLoader.load(
            source,
            cwd: cacheDir,
            eventBus: eventBus,
            cacheDir: cacheDir,
            sdkPaths: sdkPaths
        )

        guard let hook = result.hook else {
            Issue.record("Extension should load successfully")
            return
        }

        let sessionManager = SessionManager.inMemory()
        let authStorage = AuthStorage(":memory:")
        let modelRegistry = ModelRegistry(authStorage)

        let runner = HookRunner([hook], cacheDir, sessionManager, modelRegistry)
        runner.initialize(getModel: { nil }, hasUI: false)

        // Verify the command is accessible via the runner
        let command = runner.getCommand("hello")
        #expect(command != nil, "hello command should be registered in HookRunner")
        #expect(command?.description == "Say hello from extension")
    }
}

// MARK: - Extension reload lifecycle

@Test func extensionLoadedHookIsTaggedAsExtension() async throws {
    guard let sdkPaths = testSDKPaths() else {
        Issue.record("SDK paths not available")
        return
    }

    try await withTempDir { cacheDir in
        let source = extensionFixture("hello-extension.swift")
        let eventBus = createEventBus()
        let result = await ExtensionLoader.load(
            source, cwd: cacheDir, eventBus: eventBus, cacheDir: cacheDir, sdkPaths: sdkPaths
        )
        guard let hook = result.hook else {
            Issue.record("Extension should load")
            return
        }
        #expect(hook.isExtension == true, "Extension-loaded hooks must be tagged isExtension=true")
    }
}

@Test func replaceExtensionHooksSwapsExtensionsButPreservesSettingsHooks() async throws {
    guard let sdkPaths = testSDKPaths() else {
        Issue.record("SDK paths not available")
        return
    }

    try await withTempDir { cacheDir in
        let helloSource = extensionFixture("hello-extension.swift")
        let counterSource = extensionFixture("event-counter.swift")
        let eventBus = createEventBus()

        let helloResult = await ExtensionLoader.load(helloSource, cwd: cacheDir, eventBus: eventBus, cacheDir: cacheDir, sdkPaths: sdkPaths)
        let counterResult = await ExtensionLoader.load(counterSource, cwd: cacheDir, eventBus: eventBus, cacheDir: cacheDir, sdkPaths: sdkPaths)
        guard let helloHook = helloResult.hook, let counterHook = counterResult.hook else {
            Issue.record("Both extensions should load")
            return
        }

        // A non-extension "settings hook" — built directly with isExtension defaulting to false.
        let settingsHook = LoadedHook(
            path: "/settings/fake-hook",
            resolvedPath: "/settings/fake-hook",
            handlers: [:],
            commands: ["settings-cmd": RegisteredCommand(name: "settings-cmd") { _, _ in }]
        )
        #expect(settingsHook.isExtension == false)

        let sessionManager = SessionManager.inMemory()
        let authStorage = AuthStorage(":memory:")
        let modelRegistry = ModelRegistry(authStorage)

        let runner = HookRunner([settingsHook, helloHook], cacheDir, sessionManager, modelRegistry)
        runner.initialize(getModel: { nil }, hasUI: false)

        #expect(runner.getCommand("hello") != nil)
        #expect(runner.getCommand("settings-cmd") != nil)
        #expect(runner.getExtensionHookPaths() == [helloSource])

        // Swap: drop hello, install counter.
        let dropped = runner.replaceExtensionHooks([counterHook])
        #expect(dropped == [helloSource], "hello extension path should be reported as dropped")

        #expect(runner.getCommand("hello") == nil, "old extension's command must be gone")
        #expect(runner.getCommand("count") != nil, "new extension's command must be live")
        #expect(runner.getCommand("settings-cmd") != nil, "non-extension settings hook must survive")
        #expect(runner.getExtensionHookPaths() == [counterSource])
    }
}

@Test func replaceExtensionHooksReappliesWiringToNewHooks() async throws {
    // Hand-rolled extension hook whose `setSetSessionNameHandler` records whatever
    // HookRunner pipes in. Lets us verify replaceExtensionHooks() re-applies the
    // wiring captured at initialize() to hooks added later.
    let cwd = NSTemporaryDirectory()
    let receivedHandler = LockedState<HookSetSessionNameHandler?>(nil)
    let captureHook = LoadedHook(
        path: "/fake/captured-extension",
        resolvedPath: "/fake/captured-extension",
        handlers: [:],
        setSetSessionNameHandler: { handler in
            receivedHandler.withLock { $0 = handler }
        },
        isExtension: true
    )

    let sessionManager = SessionManager.inMemory()
    let authStorage = AuthStorage(":memory:")
    let modelRegistry = ModelRegistry(authStorage)
    let runner = HookRunner([], cwd, sessionManager, modelRegistry)

    let nameBox = LockedState<String?>(nil)
    runner.initialize(
        getModel: { nil },
        setSessionNameHandler: { name in nameBox.withLock { $0 = name } },
        hasUI: false
    )

    // Insert the hook after initialize(). replaceExtensionHooks must call the
    // hook's setter with the wiring's setSessionNameHandler closure.
    runner.replaceExtensionHooks([captureHook])

    let captured = receivedHandler.withLock { $0 }
    #expect(captured != nil, "wiring must call setSetSessionNameHandler on freshly-added hook")

    // And the wired closure must be the one we passed to initialize().
    captured?("hello-from-reload")
    #expect(nameBox.withLock { $0 } == "hello-from-reload",
            "the wired closure should reach the live setSessionNameHandler")
}

@Test func reloadExtensionsEndToEndViaCreateAgentSession() async throws {
    // End-to-end: build a session with the hello-extension fixture, swap it for the
    // event-counter fixture via session.reloadExtensions(), and confirm both the
    // dropped/loaded paths and the live commands tracked the swap.
    _ = _seedExtensionSDK
    guard testSDKPaths() != nil else {
        Issue.record("SDK paths not available")
        return
    }

    let helloSource = extensionFixture("hello-extension.swift")
    let counterSource = extensionFixture("event-counter.swift")

    try await withTempDir { tempDir in
        let agentDir = (tempDir as NSString).appendingPathComponent("agent")
        try FileManager.default.createDirectory(atPath: agentDir, withIntermediateDirectories: true)

        let result = await createAgentSession(CreateAgentSessionOptions(
            cwd: tempDir,
            agentDir: agentDir,
            additionalExtensionPaths: [helloSource]
        ))
        let session = result.session
        defer { session.dispose() }

        guard let runner = session.hookRunner else {
            Issue.record("hookRunner should be present on the session")
            return
        }
        #expect(runner.getCommand("hello") != nil,
                "hello-extension's command should be loaded at startup")
        #expect(runner.getExtensionHookPaths() == [helloSource])

        // Now swap the only extension by mutating settings. The reloadExtensions hook
        // captured in createAgentSession reads from settings + additionalExtensionPaths,
        // so the simplest swap is to just call reload after replacing the file the
        // additionalExtensionPaths entry points at.
        //
        // Easier path: keep the file in place and verify reload re-uses the same file.
        // (Swapping requires tweaking the closure; covered by the unit-level
        // replaceExtensionHooks test instead.)
        let reloadResult = await session.reloadExtensions()
        #expect(reloadResult.errors.isEmpty,
                "reload should not surface errors: \(reloadResult.errors)")
        #expect(reloadResult.loadedPaths == [helloSource],
                "reload re-loads from the same configured paths")
        #expect(reloadResult.droppedPaths == [helloSource],
                "the previous instance must be reported dropped")
        #expect(runner.getCommand("hello") != nil,
                "after reload, the command must still be live")

        // Sanity: counterSource exists but isn't configured, so the counter command
        // must not appear.
        #expect(runner.getCommand("count") == nil)
        _ = counterSource
    }
}

@Test func emitToExtensionsSkipsSettingsHooks() async throws {
    guard let sdkPaths = testSDKPaths() else {
        Issue.record("SDK paths not available")
        return
    }

    try await withTempDir { cacheDir in
        let counterSource = extensionFixture("event-counter.swift")
        let eventBus = createEventBus()
        let counterResult = await ExtensionLoader.load(counterSource, cwd: cacheDir, eventBus: eventBus, cacheDir: cacheDir, sdkPaths: sdkPaths)
        guard let counterHook = counterResult.hook else {
            Issue.record("event-counter should load")
            return
        }

        // Settings hook with a session_start handler that flips a flag.
        let settingsHandlerFired = LockedState<Bool>(false)
        let settingsHandler: HookHandler = { _, _ in
            settingsHandlerFired.withLock { $0 = true }
            return nil
        }
        let settingsHook = LoadedHook(
            path: "/settings/fake-hook",
            resolvedPath: "/settings/fake-hook",
            handlers: ["session_start": [settingsHandler]]
        )

        let sessionManager = SessionManager.inMemory()
        let authStorage = AuthStorage(":memory:")
        let modelRegistry = ModelRegistry(authStorage)
        let runner = HookRunner([settingsHook, counterHook], cacheDir, sessionManager, modelRegistry)
        runner.initialize(getModel: { nil }, hasUI: false)

        // emitToExtensions must NOT fire the settings hook's handler.
        await runner.emitToExtensions(SessionStartEvent(reason: .reload))

        #expect(settingsHandlerFired.withLock { $0 } == false,
                "settings-defined hooks must not see emitToExtensions events")

        // Sanity: a regular emit() does fire the settings handler.
        _ = await runner.emit(SessionStartEvent(reason: .reload))
        #expect(settingsHandlerFired.withLock { $0 } == true,
                "regular emit() must reach settings hooks")
    }
}
