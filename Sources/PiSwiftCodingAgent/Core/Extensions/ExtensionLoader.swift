import Foundation

/// Result from loading a single extension.
public struct LoadExtensionResult: Sendable {
    public let hook: LoadedHook?
    public let error: ExtensionLoadError?

    public init(hook: LoadedHook? = nil, error: ExtensionLoadError? = nil) {
        self.hook = hook
        self.error = error
    }
}

/// Extension loader -- compiles and loads plain `.swift` extensions (and SPM packages)
/// into `LoadedHook` values that merge directly into `HookRunner`.
public struct ExtensionLoader {

    /// Load a named in-process extension without compiling or opening a dylib.
    public static func load(
        _ inlineExtension: InlineExtension,
        cwd: String,
        eventBus: EventBus
    ) -> LoadExtensionResult {
        let path = inlineExtension.builtin ? "\(BUILTIN_PATH_PREFIX)\(inlineExtension.name)" : "<inline:\(inlineExtension.name)>"
        let api = HookAPI(events: eventBus, hookPath: path)
        api.setExecCwd(cwd)
        api.beginLoading()
        do {
            try inlineExtension.factory(api)
            try api.validateActive()
            api.commitLoading()
        } catch {
            api.invalidateAfterLoadFailure()
            return LoadExtensionResult(error: .invalidExtension(path: path, reason: error.localizedDescription))
        }
        return LoadExtensionResult(hook: LoadedHook(
            path: path,
            resolvedPath: path,
            handlers: api.handlers,
            currentHandlers: { api.handlers },
            messageRenderers: api.messageRenderers,
            markdownTransformers: api.markdownTransformers,
            entryRenderers: api.entryRenderers,
            commands: api.commands,
            currentCommands: { api.commands },
            flags: api.flags,
            shortcuts: api.shortcuts,
            tools: api.tools,
            currentTools: { api.tools },
            providerRegistrations: api.providerRegistrations,
            virtualModelRegistrations: api.virtualModelRegistrations,
            setSendMessageHandler: api.setSendMessageHandler,
            setSendUserMessageHandler: api.setSendUserMessageHandler,
            setAppendEntryHandler: api.setAppendEntryHandler,
            setSetSessionNameHandler: api.setSetSessionNameHandler,
            setGetSessionNameHandler: api.setGetSessionNameHandler,
            setSetLabelHandler: api.setSetLabelHandler,
            setGetActiveToolsHandler: api.setGetActiveToolsHandler,
            setGetAllToolsHandler: api.setGetAllToolsHandler,
            setGetSettingsHandler: api.setGetSettingsHandler,
            setSetActiveToolsHandler: api.setSetActiveToolsHandler,
            setGetCommandsHandler: api.setGetCommandsHandler,
            setSetModelHandler: api.setSetModelHandler,
            setGetThinkingLevelHandler: api.setGetThinkingLevelHandler,
            setSetThinkingLevelHandler: api.setSetThinkingLevelHandler,
            setRegisterProviderHandler: api.setRegisterProviderHandler,
            setUnregisterProviderHandler: api.setUnregisterProviderHandler,
            setRegisterVirtualModelHandler: api.setRegisterVirtualModelHandler,
            setUnregisterVirtualModelHandler: api.setUnregisterVirtualModelHandler,
            setRegisterToolHandler: api.setRegisterToolHandler,
            setUnregisterToolHandler: api.setUnregisterToolHandler,
            setFlagValue: api.setFlagValue,
            dispose: api.disposeEventBusListeners,
            isExtension: true,
            replaceable: inlineExtension.replaceable,
            hidden: inlineExtension.builtin
        ))
    }

    /// Load a single extension from a path.
    ///
    /// 1. Determine format: `.swift` file vs `Package.swift` directory
    /// 2. Compile via `ExtensionCompiler`
    /// 3. Load the dylib via `ExtensionDylibLoader`
    /// 4. Return the resulting `LoadedHook`
    public static func load(
        _ path: String,
        cwd: String,
        eventBus: EventBus,
        cacheDir: String,
        sdkPaths: ExtensionCompiler.SDKPaths
    ) async -> LoadExtensionResult {
        let resolvedPath = resolveToCwd(path, cwd: cwd)

        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            return LoadExtensionResult(error: .fileNotFound(path: path))
        }

        let url = URL(fileURLWithPath: resolvedPath)

        // Check if it's a directory with Package.swift
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDirectory), isDirectory.boolValue {
            let packageUrl = url.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: packageUrl.path) {
                return await loadPackageDirectory(resolvedPath, cwd: cwd, eventBus: eventBus, cacheDir: cacheDir)
            }
            return LoadExtensionResult(error: .invalidExtension(path: path, reason: "Directory has no Package.swift"))
        }

        // Otherwise treat as single Swift file
        if url.pathExtension.lowercased() == "swift" {
            return await loadSwiftFile(resolvedPath, cwd: cwd, eventBus: eventBus, cacheDir: cacheDir, sdkPaths: sdkPaths)
        }

        return LoadExtensionResult(error: .invalidExtension(path: path, reason: "Unsupported file format"))
    }

    /// Discover extensions in a directory.
    public static func discover(in dir: String) -> [String] {
        guard FileManager.default.fileExists(atPath: dir) else {
            return []
        }

        let url = URL(fileURLWithPath: dir)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else {
            return []
        }

        var results: [String] = []

        for entry in entries {
            let entryPath = entry.path
            guard !entry.lastPathComponent.hasPrefix(".") else { continue }

            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: entryPath, isDirectory: &isDir) {
                if isDir.boolValue {
                    let packageUrl = entry.appendingPathComponent("Package.swift")
                    if FileManager.default.fileExists(atPath: packageUrl.path) {
                        results.append(entryPath)
                    }
                } else if entry.pathExtension.lowercased() == "swift" {
                    results.append(entryPath)
                }
            }
        }

        return results
    }

    // MARK: - Private

    private static func loadSwiftFile(
        _ resolvedPath: String,
        cwd: String,
        eventBus: EventBus,
        cacheDir: String,
        sdkPaths: ExtensionCompiler.SDKPaths
    ) async -> LoadExtensionResult {
        do {
            let dylibPath = try await ExtensionCompiler.compileSingleFile(
                sourcePath: resolvedPath,
                cacheDir: cacheDir,
                sdkPaths: sdkPaths
            )
            let hook = try ExtensionDylibLoader.loadAndInitialize(
                dylibPath: dylibPath,
                extensionPath: resolvedPath,
                eventBus: eventBus,
                cwd: cwd
            )
            return LoadExtensionResult(hook: hook)
        } catch let error as ExtensionLoadError {
            return LoadExtensionResult(error: error)
        } catch {
            return LoadExtensionResult(error: .compilationError(path: resolvedPath, error: error.localizedDescription))
        }
    }

    private static func loadPackageDirectory(
        _ resolvedPath: String,
        cwd: String,
        eventBus: EventBus,
        cacheDir: String
    ) async -> LoadExtensionResult {
        do {
            let dylibPath = try await ExtensionCompiler.buildPackageDirectory(
                packageDir: resolvedPath,
                cacheDir: cacheDir
            )
            let hook = try ExtensionDylibLoader.loadAndInitialize(
                dylibPath: dylibPath,
                extensionPath: resolvedPath,
                eventBus: eventBus,
                cwd: cwd
            )
            return LoadExtensionResult(hook: hook)
        } catch let error as ExtensionLoadError {
            return LoadExtensionResult(error: error)
        } catch {
            return LoadExtensionResult(error: .packageLoadError(path: resolvedPath, error: error.localizedDescription))
        }
    }
}

/// Drop a replaceable extension if another extension owns one of its registrations.
public func omitReplacedExtensions(_ hooks: [LoadedHook]) -> LoadExtensionsResult {
    func names(_ hook: LoadedHook) -> [String] {
        hook.tools.keys.map { "tool:\($0)" }
            + hook.commands.keys.map { "command:\($0)" }
            + hook.flags.keys.map { "flag:\($0)" }
    }
    var taken: [String: String] = [:]
    for hook in hooks where !hook.replaceable {
        for name in names(hook) { taken[name] = hook.path }
    }
    var kept: [LoadedHook] = []
    var warnings: [ResourceDiagnostic] = []
    for hook in hooks {
        guard hook.replaceable,
              let collision = names(hook).first(where: { taken[$0] != nil }),
              let replacingPath = taken[collision] else {
            kept.append(hook)
            continue
        }
        if hook.path.hasPrefix(BUILTIN_PATH_PREFIX) {
            let parts = collision.split(separator: ":", maxSplits: 1).map(String.init)
            let kind = parts[0]
            let registered = parts.count > 1 ? parts[1] : ""
            let prefix = kind == "command" ? "/" : (kind == "flag" ? "--" : "")
            let builtin = String(hook.path.dropFirst(BUILTIN_PATH_PREFIX.count))
            warnings.append(ResourceDiagnostic(type: "warning", message:
                "Extension \(replacingPath) registers \(kind) `\(prefix)\(registered)`, so built-in extension `\(builtin)` was not loaded. To use `\(builtin)`, run `pi config` and make sure it is enabled under Built-in extensions, then disable or remove the existing extension. We recommend only having one or the other loaded at a time.", path: hook.path))
        }
    }
    return LoadExtensionsResult(hooks: kept, warnings: warnings)
}

// MARK: - Top-level loaders

/// Load extensions from multiple paths.
public func loadExtensions(
    _ paths: [String],
    cwd: String,
    eventBus: EventBus,
    cacheDir: String,
    sdkPaths: ExtensionCompiler.SDKPaths
) async -> LoadExtensionsResult {
    var hooks: [LoadedHook] = []
    var errors: [ExtensionLoadError] = []

    for path in paths {
        let result = await ExtensionLoader.load(path, cwd: cwd, eventBus: eventBus, cacheDir: cacheDir, sdkPaths: sdkPaths)
        if let hook = result.hook {
            hooks.append(hook)
        }
        if let error = result.error {
            errors.append(error)
        }
    }

    return LoadExtensionsResult(hooks: hooks, errors: errors)
}

/// Discover and load extensions from standard locations.
public func discoverAndLoadExtensions(
    _ configuredPaths: [String],
    _ cwd: String,
    _ agentDir: String = getAgentDir(),
    _ eventBus: EventBus,
    includeProjectExtensions: Bool = true,
    discoverDefaults: Bool = true
) async -> LoadExtensionsResult {
    // Resolve SDK paths -- if not available, skip extension loading. We log a warning
    // when extensions exist on disk but can't be compiled, so the failure is visible
    // (silent skipping had been confusing users on installed builds where the SDK
    // hadn't been shipped alongside the binary).
    guard let sdkPaths = ExtensionCompiler.resolveSDKPaths() else {
        let globalDir = URL(fileURLWithPath: agentDir).appendingPathComponent("extensions").path
        let localDir = URL(fileURLWithPath: cwd).appendingPathComponent(".pi").appendingPathComponent("extensions").path
        let totalCount = configuredPaths.count
            + (discoverDefaults ? ExtensionLoader.discover(in: globalDir).count : 0)
            + (discoverDefaults && includeProjectExtensions ? ExtensionLoader.discover(in: localDir).count : 0)
        if totalCount > 0 {
            FileHandle.standardError.write(Data((
                "warning: found \(totalCount) extension(s) but PiExtensionSDK is not "
                + "installed (set PI_EXTENSION_SDK_PATH, place the SDK in "
                + "~/.pi/agent/sdk/, or install via `make install`). "
                + "Extensions skipped.\n"
            ).utf8))
        }
        return LoadExtensionsResult()
    }

    let cacheDir = (agentDir as NSString).appendingPathComponent("cache/extensions")

    var allPaths: [String] = []
    var seen: Set<String> = []

    func addPath(_ path: String) {
        let resolved = resolveToCwd(path, cwd: cwd)
        if !seen.contains(resolved) {
            seen.insert(resolved)
            allPaths.append(path)
        }
    }

    // Add configured paths
    for path in configuredPaths {
        addPath(path)
    }

    // Discover global extensions
    let globalDir = URL(fileURLWithPath: agentDir).appendingPathComponent("extensions").path
    if discoverDefaults {
        for path in ExtensionLoader.discover(in: globalDir) { addPath(path) }
    }

    if discoverDefaults && includeProjectExtensions {
        let localDir = URL(fileURLWithPath: cwd).appendingPathComponent(".pi").appendingPathComponent("extensions").path
        for path in ExtensionLoader.discover(in: localDir) {
            addPath(path)
        }
    }

    return await loadExtensions(allPaths, cwd: cwd, eventBus: eventBus, cacheDir: cacheDir, sdkPaths: sdkPaths)
}
