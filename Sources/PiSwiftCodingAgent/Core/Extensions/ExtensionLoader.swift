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
    _ eventBus: EventBus
) async -> LoadExtensionsResult {
    // Resolve SDK paths -- if not available, skip extension loading. We log a warning
    // when extensions exist on disk but can't be compiled, so the failure is visible
    // (silent skipping had been confusing users on installed builds where the SDK
    // hadn't been shipped alongside the binary).
    guard let sdkPaths = ExtensionCompiler.resolveSDKPaths() else {
        let globalDir = URL(fileURLWithPath: agentDir).appendingPathComponent("extensions").path
        let localDir = URL(fileURLWithPath: cwd).appendingPathComponent(".pi").appendingPathComponent("extensions").path
        let totalCount = configuredPaths.count
            + ExtensionLoader.discover(in: globalDir).count
            + ExtensionLoader.discover(in: localDir).count
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
    for path in ExtensionLoader.discover(in: globalDir) {
        addPath(path)
    }

    // Discover local project extensions
    let localDir = URL(fileURLWithPath: cwd).appendingPathComponent(".pi").appendingPathComponent("extensions").path
    for path in ExtensionLoader.discover(in: localDir) {
        addPath(path)
    }

    return await loadExtensions(allPaths, cwd: cwd, eventBus: eventBus, cacheDir: cacheDir, sdkPaths: sdkPaths)
}
