import Foundation
import PiSwiftAI
#if canImport(CryptoKit)
import CryptoKit
#endif

public enum MissingSourceAction: String, Sendable {
    case install
    case skip
    case error
}

public struct ProgressEvent: Sendable {
    public var type: String
    public var action: String
    public var source: String
    public var message: String?

    public init(type: String, action: String, source: String, message: String? = nil) {
        self.type = type
        self.action = action
        self.source = source
        self.message = message
    }
}

public typealias ProgressCallback = @Sendable (ProgressEvent) -> Void

public struct PathMetadata: Sendable, Hashable {
    public var source: String
    public var scope: String
    public var origin: String
    public var baseDir: String?

    public init(source: String, scope: String, origin: String, baseDir: String? = nil) {
        self.source = source
        self.scope = scope
        self.origin = origin
        self.baseDir = baseDir
    }
}

/// v0.62.0: structured provenance attached to resources, commands, tools, skills, and prompt
/// templates. Visible in autocomplete, RPC discovery, and SDK introspection. Mirrors upstream
/// `SourceInfo` shape (`path` + `scope` + `source`).
///
/// In the Swift port this is a typealias to `PathMetadata` plus a `path` field, since the
/// existing `PathMetadata` already carries the same fields. New code should construct
/// `SourceInfo(path:metadata:)` to match upstream usage.
public struct SourceInfo: Sendable, Hashable {
    public var path: String
    public var source: String
    public var scope: String
    public var origin: String?
    public var baseDir: String?

    public init(path: String, source: String, scope: String, origin: String? = nil, baseDir: String? = nil) {
        self.path = path
        self.source = source
        self.scope = scope
        self.origin = origin
        self.baseDir = baseDir
    }

    public init(path: String, metadata: PathMetadata) {
        self.path = path
        self.source = metadata.source
        self.scope = metadata.scope
        self.origin = metadata.origin
        self.baseDir = metadata.baseDir
    }
}

public struct ResolvedResource: Sendable, Hashable {
    public var path: String
    public var enabled: Bool
    public var metadata: PathMetadata

    public init(path: String, enabled: Bool, metadata: PathMetadata) {
        self.path = path
        self.enabled = enabled
        self.metadata = metadata
    }
}

public struct ResolvedPaths: Sendable {
    public var extensions: [ResolvedResource]
    public var skills: [ResolvedResource]
    public var prompts: [ResolvedResource]
    public var themes: [ResolvedResource]

    public init(
        extensions: [ResolvedResource] = [],
        skills: [ResolvedResource] = [],
        prompts: [ResolvedResource] = [],
        themes: [ResolvedResource] = []
    ) {
        self.extensions = extensions
        self.skills = skills
        self.prompts = prompts
        self.themes = themes
    }
}

public struct PackageFilter: Sendable, Hashable {
    public var extensions: [String]?
    public var skills: [String]?
    public var prompts: [String]?
    public var themes: [String]?

    public init(
        extensions: [String]? = nil,
        skills: [String]? = nil,
        prompts: [String]? = nil,
        themes: [String]? = nil
    ) {
        self.extensions = extensions
        self.skills = skills
        self.prompts = prompts
        self.themes = themes
    }
}

public struct PackageFilterSource: Sendable, Hashable {
    public var source: String
    public var extensions: [String]?
    public var skills: [String]?
    public var prompts: [String]?
    public var themes: [String]?

    public init(
        source: String,
        extensions: [String]? = nil,
        skills: [String]? = nil,
        prompts: [String]? = nil,
        themes: [String]? = nil
    ) {
        self.source = source
        self.extensions = extensions
        self.skills = skills
        self.prompts = prompts
        self.themes = themes
    }

    public var filter: PackageFilter {
        PackageFilter(extensions: extensions, skills: skills, prompts: prompts, themes: themes)
    }
}

public enum PackageSource: Sendable, Hashable {
    case simple(String)
    case filtered(PackageFilterSource)

    public var source: String {
        switch self {
        case .simple(let value):
            return value
        case .filtered(let value):
            return value.source
        }
    }

    public var filter: PackageFilter? {
        switch self {
        case .simple:
            return nil
        case .filtered(let value):
            return value.filter
        }
    }
}

public protocol PackageManager: Sendable {
    func resolve(onMissing: (@Sendable (String) async -> MissingSourceAction)?) async throws -> ResolvedPaths
    func resolveExtensionSources(
        _ sources: [String],
        options: PackageResolveOptions
    ) async throws -> ResolvedPaths
    func install(_ source: String, options: PackageResolveOptions) async throws
    func remove(_ source: String, options: PackageResolveOptions) async throws
    func update(_ source: String?) async throws
    func setProgressCallback(_ callback: ProgressCallback?)
    func getInstalledPath(_ source: String, scope: String) -> String?
}

public struct PackageResolveOptions: Sendable {
    public var local: Bool
    public var temporary: Bool
    public var offline: Bool

    public init(local: Bool = false, temporary: Bool = false, offline: Bool = false) {
        self.local = local
        self.temporary = temporary
        self.offline = offline
    }
}

public final class DefaultPackageManager: PackageManager {
    private let cwd: String
    private let agentDir: String
    private let settingsManager: SettingsManager
    private let projectTrusted: Bool
    private let offline: Bool
    private struct State: Sendable {
        var globalNpmRoot: String?
        var progressCallback: ProgressCallback?
    }
    private let state = LockedState(State())
    private let commandRunnerOverride = LockedState<(@Sendable (String, [String], String) async throws -> ExecResult)?>(nil)

    private var globalNpmRoot: String? {
        get { state.withLock { $0.globalNpmRoot } }
        set { state.withLock { $0.globalNpmRoot = newValue } }
    }

    private var progressCallback: ProgressCallback? {
        get { state.withLock { $0.progressCallback } }
        set { state.withLock { $0.progressCallback = newValue } }
    }

    public init(cwd: String, agentDir: String, settingsManager: SettingsManager, projectTrusted: Bool = true, offline: Bool = false) {
        self.cwd = cwd
        self.agentDir = agentDir
        self.settingsManager = settingsManager
        self.projectTrusted = projectTrusted
        self.offline = offline
    }

    public func setProgressCallback(_ callback: ProgressCallback?) {
        self.progressCallback = callback
    }

    func setCommandRunnerForTests(_ runner: (@Sendable (String, [String], String) async throws -> ExecResult)?) {
        commandRunnerOverride.withLock { state in
            state = runner
        }
    }

    public func getInstalledPath(_ source: String, scope: String) -> String? {
        let parsed = parseSource(source)
        switch parsed {
        case .npm(let npm):
            let path = getNpmInstallPath(npm, scope: scope)
            return FileManager.default.fileExists(atPath: path) ? path : nil
        case .git(let git):
            let path = getGitInstallPath(git, scope: scope)
            return FileManager.default.fileExists(atPath: path) ? path : nil
        case .local(let local):
            let baseDir = getBaseDirForScope(scope)
            let path = resolvePathFromBase(local.path, baseDir: baseDir)
            return FileManager.default.fileExists(atPath: path) ? path : nil
        }
    }

    public func resolve(onMissing: (@Sendable (String) async -> MissingSourceAction)? = nil) async throws -> ResolvedPaths {
        let accumulator = ResourceAccumulator()
        let globalSettings = settingsManager.getGlobalSettings()
        let projectSettings = projectTrusted ? settingsManager.getProjectSettings() : Settings()

        var allPackages: [(PackageSource, String)] = []
        for pkg in globalSettings.packages ?? [] {
            allPackages.append((pkg, "user"))
        }
        for pkg in projectSettings.packages ?? [] {
            allPackages.append((pkg, "project"))
        }

        let packageSources = dedupePackages(allPackages)
        try await resolvePackageSources(packageSources, accumulator: accumulator, onMissing: onMissing, offline: offline)

        let globalBaseDir = agentDir
        let projectBaseDir = URL(fileURLWithPath: cwd).appendingPathComponent(CONFIG_DIR_NAME).path

        for resourceType in ResourceType.allCases {
            let globalEntries = globalSettings.paths(for: resourceType)
            let projectEntries = projectSettings.paths(for: resourceType)

            resolveLocalEntries(
                entries: globalEntries,
                resourceType: resourceType,
                accumulator: accumulator,
                metadata: PathMetadata(source: "local", scope: "user", origin: "top-level"),
                baseDir: globalBaseDir
            )
            resolveLocalEntries(
                entries: projectEntries,
                resourceType: resourceType,
                accumulator: accumulator,
                metadata: PathMetadata(source: "local", scope: "project", origin: "top-level"),
                baseDir: projectBaseDir
            )
        }

        addAutoDiscoveredResources(
            accumulator: accumulator,
            globalSettings: globalSettings,
            projectSettings: projectSettings,
            globalBaseDir: globalBaseDir,
            projectBaseDir: projectBaseDir
        )

        return accumulator.toResolvedPaths()
    }

    public func resolveExtensionSources(
        _ sources: [String],
        options: PackageResolveOptions = PackageResolveOptions()
    ) async throws -> ResolvedPaths {
        let accumulator = ResourceAccumulator()
        let scope = options.temporary ? "temporary" : (options.local ? "project" : "user")
        let packageSources = sources.map { (PackageSource.simple($0), scope) }
        try await resolvePackageSources(packageSources, accumulator: accumulator, onMissing: nil, offline: offline || options.offline)
        return accumulator.toResolvedPaths()
    }

    public func install(_ source: String, options: PackageResolveOptions = PackageResolveOptions()) async throws {
        let parsed = parseSource(source)
        let scope = options.local ? "project" : "user"
        try await withProgress(action: "install", source: source, message: "Installing \(source)...") {
            switch parsed {
            case .npm(let npm):
                guard !self.offline && !options.offline else {
                    throw PackageManagerError.unsupported(Self.offlineInstallMessage)
                }
                try await installNpm(npm, scope: scope, temporary: false)
            case .git(let git):
                guard !self.offline && !options.offline else {
                    throw PackageManagerError.unsupported(Self.offlineInstallMessage)
                }
                try await installGit(git, scope: scope)
            case .local(let local):
                let resolved = resolvePath(local.path)
                var isDir: ObjCBool = false
                if !FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir) {
                    throw PackageManagerError.unsupported("Path does not exist: \(resolved)")
                }
            }
        }
    }

    public func remove(_ source: String, options: PackageResolveOptions = PackageResolveOptions()) async throws {
        let parsed = parseSource(source)
        let scope = options.local ? "project" : "user"
        try await withProgress(action: "remove", source: source, message: "Removing \(source)...") {
            switch parsed {
            case .npm(let npm):
                try await uninstallNpm(npm, scope: scope)
            case .git(let git):
                try await removeGit(git, scope: scope)
            case .local:
                return
            }
        }
    }

    public func update(_ source: String?) async throws {
        guard !offline else {
            throw PackageManagerError.unsupported(Self.offlineUpdateMessage)
        }
        let globalSettings = settingsManager.getGlobalSettings()
        let projectSettings = projectTrusted ? settingsManager.getProjectSettings() : Settings()

        let identity = source.map { getPackageIdentity($0) }

        for pkg in globalSettings.packages ?? [] {
            let sourceStr = packageSourceString(pkg)
            if let identity, getPackageIdentity(sourceStr) != identity {
                continue
            }
            try await updateSource(source: sourceStr, scope: "user")
        }
        for pkg in projectSettings.packages ?? [] {
            let sourceStr = packageSourceString(pkg)
            if let identity, getPackageIdentity(sourceStr) != identity {
                continue
            }
            try await updateSource(source: sourceStr, scope: "project")
        }
    }

    private func updateSource(source: String, scope: String) async throws {
        let parsed = parseSource(source)
        switch parsed {
        case .npm(let npm):
            if npm.pinned { return }
            try await withProgress(action: "update", source: source, message: "Updating \(source)...") {
                try await installNpm(npm, scope: scope, temporary: false)
            }
        case .git(let git):
            if git.pinned { return }
            try await withProgress(action: "update", source: source, message: "Updating \(source)...") {
                try await updateGit(git, scope: scope)
            }
        case .local:
            return
        }
    }

    private func withProgress(action: String, source: String, message: String, operation: () async throws -> Void) async throws {
        progressCallback?(ProgressEvent(type: "start", action: action, source: source, message: message))
        do {
            try await operation()
            progressCallback?(ProgressEvent(type: "complete", action: action, source: source))
        } catch {
            progressCallback?(ProgressEvent(type: "error", action: action, source: source, message: error.localizedDescription))
            throw error
        }
    }

    private func resolvePackageSources(
        _ sources: [(PackageSource, String)],
        accumulator: ResourceAccumulator,
        onMissing: (@Sendable (String) async -> MissingSourceAction)?,
        offline: Bool
    ) async throws {
        for (pkg, scope) in sources {
            let sourceStr = pkg.source
            let filter = pkg.filter
            let parsed = parseSource(sourceStr)
            var metadata = PathMetadata(source: sourceStr, scope: scope, origin: "package")

            if case .local(let local) = parsed {
                resolveLocalExtensionSource(local, accumulator: accumulator, filter: filter, metadata: &metadata)
                continue
            }

            let installMissing: () async throws -> Bool = {
                if offline {
                    return false
                }
                if let onMissing {
                    let action = await onMissing(sourceStr)
                    switch action {
                    case .skip:
                        return false
                    case .error:
                        throw PackageManagerError.missing("Missing source: \(sourceStr)")
                    case .install:
                        break
                    }
                }
                try await self.installParsedSource(parsed, scope: scope)
                return true
            }

            switch parsed {
            case .npm(let npm):
                let installedPath = getNpmInstallPath(npm, scope: scope)
                let installed = FileManager.default.fileExists(atPath: installedPath)
                let needsInstall: Bool
                if installed {
                    needsInstall = offline ? false : try await npmNeedsUpdate(npm, installedPath: installedPath)
                } else {
                    needsInstall = true
                }
                if needsInstall {
                    let installed = try await installMissing()
                    if !installed { continue }
                }
                metadata.baseDir = installedPath
                _ = collectPackageResources(packageRoot: installedPath, accumulator: accumulator, filter: filter, metadata: metadata)
            case .git(let git):
                let installedPath = getGitInstallPath(git, scope: scope)
                if !FileManager.default.fileExists(atPath: installedPath) {
                    let installed = try await installMissing()
                    if !installed { continue }
                } else if scope == "temporary" && !git.pinned && !offline {
                    await refreshTemporaryGitSource(git, source: sourceStr)
                }
                metadata.baseDir = installedPath
                _ = collectPackageResources(packageRoot: installedPath, accumulator: accumulator, filter: filter, metadata: metadata)
            case .local:
                break
            }
        }
    }

    private func resolveLocalExtensionSource(
        _ source: LocalSource,
        accumulator: ResourceAccumulator,
        filter: PackageFilter?,
        metadata: inout PathMetadata
    ) {
        let resolved = resolvePath(source.path)
        guard FileManager.default.fileExists(atPath: resolved) else { return }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir) else { return }

        if !isDir.boolValue {
            metadata.baseDir = (resolved as NSString).deletingLastPathComponent
            accumulator.add(resourceType: .extensions, path: resolved, metadata: metadata, enabled: true)
            return
        }

        metadata.baseDir = resolved
        let hadResources = collectPackageResources(packageRoot: resolved, accumulator: accumulator, filter: filter, metadata: metadata)
        if !hadResources {
            accumulator.add(resourceType: .extensions, path: resolved, metadata: metadata, enabled: true)
        }
    }

    private func installParsedSource(_ parsed: ParsedSource, scope: String) async throws {
        switch parsed {
        case .npm(let npm):
            try await installNpm(npm, scope: scope, temporary: scope == "temporary")
        case .git(let git):
            try await installGit(git, scope: scope)
        case .local:
            return
        }
    }

    private static let offlineInstallMessage = "Offline mode is enabled; package install is unavailable"
    private static let offlineUpdateMessage = "Offline mode is enabled; package update is unavailable"

    private func npmNeedsUpdate(_ source: NpmSource, installedPath: String) async throws -> Bool {
        guard let installedVersion = getInstalledNpmVersion(installedPath: installedPath) else { return true }
        if let pinned = parseNpmSpec(source.spec).version {
            return installedVersion != pinned
        }
        guard let latest = try await getLatestNpmVersion(packageName: source.name) else { return false }
        return latest != installedVersion
    }

    private func getInstalledNpmVersion(installedPath: String) -> String? {
        let packageJsonPath = URL(fileURLWithPath: installedPath).appendingPathComponent("package.json").path
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: packageJsonPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["version"] as? String
    }

    private func getLatestNpmVersion(packageName: String) async throws -> String? {
        #if canImport(UIKit)
        return nil
        #else
        let result = try await runCommand("npm", ["view", packageName, "version"], cwd: cwd)
        if result.code != 0 {
            return nil
        }
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
        #endif
    }

    private func parseNpmSpec(_ spec: String) -> (name: String, version: String?) {
        if let atIndex = spec.lastIndex(of: "@"), atIndex != spec.startIndex {
            let name = String(spec[..<atIndex])
            let version = String(spec[spec.index(after: atIndex)...])
            if !name.isEmpty && !version.isEmpty {
                return (name, version)
            }
        }
        return (spec, nil)
    }

    /// v0.62.0: resolve the configured npm command (`["mise", "exec", "node@20", "--", "npm"]`,
    /// `["pnpm"]`, etc.) and split into `(executable, prefixArgs)`. Falls back to `("npm", [])`
    /// when settings.npmCommand is unset.
    private func resolvedNpmCommand() -> (executable: String, prefixArgs: [String]) {
        guard let cmd = settingsManager.getNpmCommand(), let head = cmd.first else {
            return ("npm", [])
        }
        return (head, Array(cmd.dropFirst()))
    }

    private func installNpm(_ source: NpmSource, scope: String, temporary: Bool) async throws {
        #if canImport(UIKit)
        throw PackageManagerError.unsupported("npm install not available")
        #else
        let (npmExe, npmPrefix) = resolvedNpmCommand()
        if scope == "user" && !temporary {
            _ = try await runCommand(npmExe, npmPrefix + ["install", "-g", source.spec], cwd: cwd)
            return
        }
        let installRoot = getNpmInstallRoot(scope: scope, temporary: temporary)
        try ensureNpmProject(installRoot)
        _ = try await runCommand(npmExe, npmPrefix + ["install", source.spec, "--prefix", installRoot], cwd: cwd)
        #endif
    }

    private func uninstallNpm(_ source: NpmSource, scope: String) async throws {
        #if canImport(UIKit)
        throw PackageManagerError.unsupported("npm uninstall not available")
        #else
        let (npmExe, npmPrefix) = resolvedNpmCommand()
        if scope == "user" {
            _ = try await runCommand(npmExe, npmPrefix + ["uninstall", "-g", source.name], cwd: cwd)
            return
        }
        let installRoot = getNpmInstallRoot(scope: scope, temporary: false)
        guard FileManager.default.fileExists(atPath: installRoot) else { return }
        _ = try await runCommand(npmExe, npmPrefix + ["uninstall", source.name, "--prefix", installRoot], cwd: cwd)
        #endif
    }

    private func installGit(_ source: GitSource, scope: String) async throws {
        #if canImport(UIKit)
        throw PackageManagerError.unsupported("git install not available")
        #else
        let targetDir = getGitInstallPath(source, scope: scope)
        if FileManager.default.fileExists(atPath: targetDir) {
            return
        }
        if let gitRoot = getGitInstallRoot(scope: scope) {
            try ensureGitIgnore(gitRoot)
        }
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: (targetDir as NSString).deletingLastPathComponent), withIntermediateDirectories: true)
        let cloneUrl: String
        if source.repo.hasPrefix("http") || source.repo.hasPrefix("git@") || source.repo.hasPrefix("ssh://") {
            cloneUrl = source.repo
        } else {
            cloneUrl = "https://\(source.repo)"
        }
        _ = try await runCommand("git", ["clone", cloneUrl, targetDir], cwd: cwd)
        if let ref = source.ref {
            _ = try await runCommand("git", ["checkout", ref], cwd: targetDir)
        }
        let packageJsonPath = URL(fileURLWithPath: targetDir).appendingPathComponent("package.json").path
        if FileManager.default.fileExists(atPath: packageJsonPath) {
            let (npmExe, npmPrefix) = resolvedNpmCommand()
            _ = try await runCommand(npmExe, npmPrefix + ["install"], cwd: targetDir)
        }
        #endif
    }

    private func updateGit(_ source: GitSource, scope: String) async throws {
        #if canImport(UIKit)
        throw PackageManagerError.unsupported("git update not available")
        #else
        let targetDir = getGitInstallPath(source, scope: scope)
        if !FileManager.default.fileExists(atPath: targetDir) {
            try await installGit(source, scope: scope)
            return
        }
        _ = try await runCommand("git", ["fetch", "--prune", "origin"], cwd: targetDir)
        do {
            _ = try await runCommand("git", ["reset", "--hard", "@{upstream}"], cwd: targetDir)
        } catch {
            _ = try? await runCommand("git", ["remote", "set-head", "origin", "-a"], cwd: targetDir)
            _ = try await runCommand("git", ["reset", "--hard", "origin/HEAD"], cwd: targetDir)
        }
        _ = try await runCommand("git", ["clean", "-fdx"], cwd: targetDir)
        let packageJsonPath = URL(fileURLWithPath: targetDir).appendingPathComponent("package.json").path
        if FileManager.default.fileExists(atPath: packageJsonPath) {
            let (npmExe, npmPrefix) = resolvedNpmCommand()
            _ = try await runCommand(npmExe, npmPrefix + ["install"], cwd: targetDir)
        }
        #endif
    }

    private func refreshTemporaryGitSource(_ source: GitSource, source sourceStr: String) async {
        do {
            try await withProgress(action: "pull", source: sourceStr, message: "Refreshing \(sourceStr)...") {
                try await self.updateGit(source, scope: "temporary")
            }
        } catch {
            // Keep cached temporary checkout if refresh fails.
        }
    }

    private func removeGit(_ source: GitSource, scope: String) async throws {
        let targetDir = getGitInstallPath(source, scope: scope)
        guard FileManager.default.fileExists(atPath: targetDir) else { return }
        try FileManager.default.removeItem(at: URL(fileURLWithPath: targetDir))
        pruneEmptyGitParents(targetDir: targetDir, installRoot: getGitInstallRoot(scope: scope))
    }

    private func pruneEmptyGitParents(targetDir: String, installRoot: String?) {
        guard let installRoot else { return }
        let resolvedRoot = URL(fileURLWithPath: installRoot).standardized.path
        var current = (targetDir as NSString).deletingLastPathComponent
        while current.hasPrefix(resolvedRoot), current != resolvedRoot {
            guard FileManager.default.fileExists(atPath: current) else {
                current = (current as NSString).deletingLastPathComponent
                continue
            }
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: current)) ?? []
            if !entries.isEmpty {
                break
            }
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: current))
            current = (current as NSString).deletingLastPathComponent
        }
    }

    private func ensureNpmProject(_ installRoot: String) throws {
        if !FileManager.default.fileExists(atPath: installRoot) {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: installRoot), withIntermediateDirectories: true)
        }
        try ensureGitIgnore(installRoot)
        let packageJsonPath = URL(fileURLWithPath: installRoot).appendingPathComponent("package.json").path
        if !FileManager.default.fileExists(atPath: packageJsonPath) {
            let payload: [String: Any] = ["name": "pi-extensions", "private": true]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
            try data.write(to: URL(fileURLWithPath: packageJsonPath))
        }
    }

    private func ensureGitIgnore(_ dir: String) throws {
        if !FileManager.default.fileExists(atPath: dir) {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: dir), withIntermediateDirectories: true)
        }
        let ignorePath = URL(fileURLWithPath: dir).appendingPathComponent(".gitignore").path
        if !FileManager.default.fileExists(atPath: ignorePath) {
            try "*\n!.gitignore\n".write(toFile: ignorePath, atomically: true, encoding: .utf8)
        }
    }

    private func getNpmInstallRoot(scope: String, temporary: Bool) -> String {
        if temporary {
            return getTemporaryDir(prefix: "npm", suffix: nil)
        }
        if scope == "project" {
            return URL(fileURLWithPath: cwd).appendingPathComponent(CONFIG_DIR_NAME).appendingPathComponent("npm").path
        }
        return (getGlobalNpmRoot() as NSString).deletingLastPathComponent
    }

    private func getGlobalNpmRoot() -> String {
        if let globalNpmRoot { return globalNpmRoot }
        #if canImport(UIKit)
        let fallback = URL(fileURLWithPath: agentDir).appendingPathComponent("npm").path
        globalNpmRoot = fallback
        return fallback
        #else
        let result = runCommandSync("npm", ["root", "-g"])
        globalNpmRoot = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return globalNpmRoot ?? ""
        #endif
    }

    private func getNpmInstallPath(_ source: NpmSource, scope: String) -> String {
        if scope == "temporary" {
            return URL(fileURLWithPath: getTemporaryDir(prefix: "npm", suffix: nil))
                .appendingPathComponent("node_modules")
                .appendingPathComponent(source.name).path
        }
        if scope == "project" {
            return URL(fileURLWithPath: cwd)
                .appendingPathComponent(CONFIG_DIR_NAME)
                .appendingPathComponent("npm")
                .appendingPathComponent("node_modules")
                .appendingPathComponent(source.name).path
        }
        return URL(fileURLWithPath: getGlobalNpmRoot()).appendingPathComponent(source.name).path
    }

    private func getGitInstallPath(_ source: GitSource, scope: String) -> String {
        if scope == "temporary" {
            return getTemporaryDir(prefix: "git-\(source.host)", suffix: source.path)
        }
        if scope == "project" {
            return URL(fileURLWithPath: cwd)
                .appendingPathComponent(CONFIG_DIR_NAME)
                .appendingPathComponent("git")
                .appendingPathComponent(source.host)
                .appendingPathComponent(source.path).path
        }
        return URL(fileURLWithPath: agentDir)
            .appendingPathComponent("git")
            .appendingPathComponent(source.host)
            .appendingPathComponent(source.path).path
    }

    private func getGitInstallRoot(scope: String) -> String? {
        if scope == "temporary" { return nil }
        if scope == "project" {
            return URL(fileURLWithPath: cwd).appendingPathComponent(CONFIG_DIR_NAME).appendingPathComponent("git").path
        }
        return URL(fileURLWithPath: agentDir).appendingPathComponent("git").path
    }

    private func getTemporaryDir(prefix: String, suffix: String?) -> String {
        let base = "\(prefix)-\(suffix ?? "")"
        let hash = sha256(base).prefix(8)
        let tmp = NSTemporaryDirectory()
        if let suffix, !suffix.isEmpty {
            return URL(fileURLWithPath: tmp).appendingPathComponent("pi-extensions").appendingPathComponent(prefix).appendingPathComponent(String(hash)).appendingPathComponent(suffix).path
        }
        return URL(fileURLWithPath: tmp).appendingPathComponent("pi-extensions").appendingPathComponent(prefix).appendingPathComponent(String(hash)).path
    }

    private func resolvePath(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "~" {
            return canonicalize(getHomeDir())
        }
        if trimmed.hasPrefix("~/") {
            return canonicalize(URL(fileURLWithPath: getHomeDir()).appendingPathComponent(String(trimmed.dropFirst(2))).path)
        }
        if trimmed.hasPrefix("~") {
            return canonicalize(URL(fileURLWithPath: getHomeDir()).appendingPathComponent(String(trimmed.dropFirst())).path)
        }
        if trimmed.hasPrefix("/") {
            return canonicalize(URL(fileURLWithPath: trimmed).path)
        }
        if trimmed.count >= 3 {
            let chars = Array(trimmed)
            if chars[1] == ":", (chars[2] == "/" || chars[2] == "\\") {
                return canonicalize(URL(fileURLWithPath: trimmed).path)
            }
        }
        if trimmed.hasPrefix("\\\\") {
            return canonicalize(URL(fileURLWithPath: trimmed).path)
        }
        return canonicalize(URL(fileURLWithPath: cwd).appendingPathComponent(trimmed).path)
    }

    private func resolvePathFromBase(_ input: String, baseDir: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "~" {
            return canonicalize(getHomeDir())
        }
        if trimmed.hasPrefix("~/") {
            return canonicalize(URL(fileURLWithPath: getHomeDir()).appendingPathComponent(String(trimmed.dropFirst(2))).path)
        }
        if trimmed.hasPrefix("~") {
            return canonicalize(URL(fileURLWithPath: getHomeDir()).appendingPathComponent(String(trimmed.dropFirst())).path)
        }
        if trimmed.hasPrefix("/") {
            return canonicalize(URL(fileURLWithPath: trimmed).path)
        }
        if trimmed.count >= 3 {
            let chars = Array(trimmed)
            if chars[1] == ":", (chars[2] == "/" || chars[2] == "\\") {
                return canonicalize(URL(fileURLWithPath: trimmed).path)
            }
        }
        if trimmed.hasPrefix("\\\\") {
            return canonicalize(URL(fileURLWithPath: trimmed).path)
        }
        return canonicalize(URL(fileURLWithPath: baseDir).appendingPathComponent(trimmed).path)
    }

    private func canonicalize(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardized.path
    }

    private func collectPackageResources(
        packageRoot: String,
        accumulator: ResourceAccumulator,
        filter: PackageFilter?,
        metadata: PathMetadata
    ) -> Bool {
        if let filter {
            for resourceType in ResourceType.allCases {
                let patterns = filter.patterns(for: resourceType)
                if patterns != nil {
                    applyPackageFilter(packageRoot: packageRoot, userPatterns: patterns ?? [], resourceType: resourceType, accumulator: accumulator, metadata: metadata)
                } else {
                    collectDefaultResources(packageRoot: packageRoot, resourceType: resourceType, accumulator: accumulator, metadata: metadata)
                }
            }
            return true
        }

        if let manifest = readPiManifest(packageRoot: packageRoot) {
            for resourceType in ResourceType.allCases {
                let entries = manifest.entries(for: resourceType)
                addManifestEntries(entries: entries, root: packageRoot, resourceType: resourceType, accumulator: accumulator, metadata: metadata)
            }
            return true
        }

        var hasAnyDir = false
        for resourceType in ResourceType.allCases {
            let dir = URL(fileURLWithPath: packageRoot).appendingPathComponent(resourceType.rawValue).path
            if FileManager.default.fileExists(atPath: dir) {
                let files = collectResourceFiles(dir: dir, resourceType: resourceType)
                for file in files {
                    accumulator.add(resourceType: resourceType, path: file, metadata: metadata, enabled: true)
                }
                hasAnyDir = true
            }
        }
        return hasAnyDir
    }

    private func collectDefaultResources(
        packageRoot: String,
        resourceType: ResourceType,
        accumulator: ResourceAccumulator,
        metadata: PathMetadata
    ) {
        if let manifest = readPiManifest(packageRoot: packageRoot), let entries = manifest.entries(for: resourceType) {
            addManifestEntries(entries: entries, root: packageRoot, resourceType: resourceType, accumulator: accumulator, metadata: metadata)
            return
        }
        let dir = URL(fileURLWithPath: packageRoot).appendingPathComponent(resourceType.rawValue).path
        guard FileManager.default.fileExists(atPath: dir) else { return }
        let files = collectResourceFiles(dir: dir, resourceType: resourceType)
        for file in files {
            accumulator.add(resourceType: resourceType, path: file, metadata: metadata, enabled: true)
        }
    }

    private func applyPackageFilter(
        packageRoot: String,
        userPatterns: [String],
        resourceType: ResourceType,
        accumulator: ResourceAccumulator,
        metadata: PathMetadata
    ) {
        let manifestFiles = collectManifestFiles(packageRoot: packageRoot, resourceType: resourceType)
        if userPatterns.isEmpty {
            for file in manifestFiles.allFiles {
                accumulator.add(resourceType: resourceType, path: file, metadata: metadata, enabled: false)
            }
            return
        }

        let enabled = applyPatterns(allPaths: manifestFiles.allFiles, patterns: userPatterns, baseDir: packageRoot)
        for file in manifestFiles.allFiles {
            accumulator.add(resourceType: resourceType, path: file, metadata: metadata, enabled: enabled.contains(file))
        }
    }

    private func collectManifestFiles(packageRoot: String, resourceType: ResourceType) -> (allFiles: [String], enabledByManifest: Set<String>) {
        if let manifest = readPiManifest(packageRoot: packageRoot), let entries = manifest.entries(for: resourceType), !entries.isEmpty {
            let allFiles = collectFilesFromManifestEntries(entries: entries, root: packageRoot, resourceType: resourceType)
            let manifestPatterns = entries.filter { isPattern($0) }
            let enabled = manifestPatterns.isEmpty ? Set(allFiles) : applyPatterns(allPaths: allFiles, patterns: manifestPatterns, baseDir: packageRoot)
            return (Array(enabled), enabled)
        }

        let conventionDir = URL(fileURLWithPath: packageRoot).appendingPathComponent(resourceType.rawValue).path
        guard FileManager.default.fileExists(atPath: conventionDir) else {
            return ([], Set())
        }
        let allFiles = collectResourceFiles(dir: conventionDir, resourceType: resourceType)
        return (allFiles, Set(allFiles))
    }

    private func readPiManifest(packageRoot: String) -> PiManifest? {
        let packageJsonPath = URL(fileURLWithPath: packageRoot).appendingPathComponent("package.json").path
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: packageJsonPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pi = json["pi"] as? [String: Any] else {
            return nil
        }
        return PiManifest(raw: pi)
    }

    private func addManifestEntries(
        entries: [String]?,
        root: String,
        resourceType: ResourceType,
        accumulator: ResourceAccumulator,
        metadata: PathMetadata
    ) {
        guard let entries else { return }
        let allFiles = collectFilesFromManifestEntries(entries: entries, root: root, resourceType: resourceType)
        let patterns = entries.filter { isPattern($0) }
        let enabledPaths = applyPatterns(allPaths: allFiles, patterns: patterns, baseDir: root)
        for file in allFiles where enabledPaths.contains(file) {
            accumulator.add(resourceType: resourceType, path: file, metadata: metadata, enabled: true)
        }
    }

    private func collectFilesFromManifestEntries(entries: [String], root: String, resourceType: ResourceType) -> [String] {
        let plain = entries.filter { !isPattern($0) }
        let resolved = plain.map { URL(fileURLWithPath: root).appendingPathComponent($0).path }
        return collectFilesFromPaths(paths: resolved, resourceType: resourceType)
    }

    private func resolveLocalEntries(
        entries: [String],
        resourceType: ResourceType,
        accumulator: ResourceAccumulator,
        metadata: PathMetadata,
        baseDir: String
    ) {
        guard !entries.isEmpty else { return }
        let split = splitPatterns(entries)
        let resolvedPlain = split.plain.map { resolvePathFromBase($0, baseDir: baseDir) }
        let allFiles = collectFilesFromPaths(paths: resolvedPlain, resourceType: resourceType)
        let enabledPaths = applyPatterns(allPaths: allFiles, patterns: split.patterns, baseDir: baseDir)
        for file in allFiles {
            accumulator.add(resourceType: resourceType, path: file, metadata: metadata, enabled: enabledPaths.contains(file))
        }
    }

    private func addAutoDiscoveredResources(
        accumulator: ResourceAccumulator,
        globalSettings: Settings,
        projectSettings: Settings,
        globalBaseDir: String,
        projectBaseDir: String
    ) {
        // Resolve symlinks to handle /var vs /private/var on macOS
        let standardGlobalBaseDir = resolveRealPath(globalBaseDir)
        let standardProjectBaseDir = resolveRealPath(projectBaseDir)

        let userMetadata = PathMetadata(source: "auto", scope: "user", origin: "top-level", baseDir: globalBaseDir)
        let projectMetadata = PathMetadata(source: "auto", scope: "project", origin: "top-level", baseDir: projectBaseDir)

        let userOverrides = SettingsPaths(
            extensions: globalSettings.extensions ?? [],
            skills: globalSettings.skillPaths ?? [],
            prompts: globalSettings.prompts ?? [],
            themes: globalSettings.themes ?? []
        )
        let projectOverrides = SettingsPaths(
            extensions: projectSettings.extensions ?? [],
            skills: projectSettings.skillPaths ?? [],
            prompts: projectSettings.prompts ?? [],
            themes: projectSettings.themes ?? []
        )

        let userDirs = SettingsPaths(
            extensions: [URL(fileURLWithPath: standardGlobalBaseDir).appendingPathComponent("extensions").path],
            skills: [URL(fileURLWithPath: standardGlobalBaseDir).appendingPathComponent("skills").path],
            prompts: [URL(fileURLWithPath: standardGlobalBaseDir).appendingPathComponent("prompts").path],
            themes: [URL(fileURLWithPath: standardGlobalBaseDir).appendingPathComponent("themes").path]
        )
        let projectDirs = SettingsPaths(
            extensions: [URL(fileURLWithPath: standardProjectBaseDir).appendingPathComponent("extensions").path],
            skills: [URL(fileURLWithPath: standardProjectBaseDir).appendingPathComponent("skills").path],
            prompts: [URL(fileURLWithPath: standardProjectBaseDir).appendingPathComponent("prompts").path],
            themes: [URL(fileURLWithPath: standardProjectBaseDir).appendingPathComponent("themes").path]
        )
        // Match upstream: prefer `$HOME` env var over `homedir()` so tests can isolate
        // `~/.agents/skills` against the test's own temp HOME. (pi-mono: `getHomeDir()`.)
        let homeDir = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let userAgentsSkillsDir = URL(fileURLWithPath: homeDir).appendingPathComponent(".agents").appendingPathComponent("skills").path
        let projectAgentsSkillDirs = collectAncestorAgentsSkillDirs(startDir: cwd)

        func addResources(
            resourceType: ResourceType,
            paths: [String],
            metadata: PathMetadata,
            overrides: [String],
            baseDir: String
        ) {
            for path in paths {
                let enabled = isEnabledByOverrides(filePath: path, patterns: overrides, baseDir: baseDir)
                accumulator.add(resourceType: resourceType, path: path, metadata: metadata, enabled: enabled)
            }
        }

        addResources(
            resourceType: .extensions,
            paths: collectAutoExtensionEntries(dir: userDirs.extensions.first ?? ""),
            metadata: userMetadata,
            overrides: userOverrides.extensions,
            baseDir: standardGlobalBaseDir
        )
        addResources(
            resourceType: .skills,
            paths: collectAutoSkillEntries(dir: userDirs.skills.first ?? "") + collectAutoSkillEntries(dir: userAgentsSkillsDir),
            metadata: userMetadata,
            overrides: userOverrides.skills,
            baseDir: standardGlobalBaseDir
        )
        addResources(
            resourceType: .prompts,
            paths: collectAutoPromptEntries(dir: userDirs.prompts.first ?? ""),
            metadata: userMetadata,
            overrides: userOverrides.prompts,
            baseDir: standardGlobalBaseDir
        )
        addResources(
            resourceType: .themes,
            paths: collectAutoThemeEntries(dir: userDirs.themes.first ?? ""),
            metadata: userMetadata,
            overrides: userOverrides.themes,
            baseDir: standardGlobalBaseDir
        )

        if projectTrusted {
            addResources(
                resourceType: .extensions,
                paths: collectAutoExtensionEntries(dir: projectDirs.extensions.first ?? ""),
                metadata: projectMetadata,
                overrides: projectOverrides.extensions,
                baseDir: standardProjectBaseDir
            )
            addResources(
                resourceType: .skills,
                paths: collectAutoSkillEntries(dir: projectDirs.skills.first ?? "") + projectAgentsSkillDirs.flatMap { collectAutoSkillEntries(dir: $0) },
                metadata: projectMetadata,
                overrides: projectOverrides.skills,
                baseDir: standardProjectBaseDir
            )
            addResources(
                resourceType: .prompts,
                paths: collectAutoPromptEntries(dir: projectDirs.prompts.first ?? ""),
                metadata: projectMetadata,
                overrides: projectOverrides.prompts,
                baseDir: standardProjectBaseDir
            )
            addResources(
                resourceType: .themes,
                paths: collectAutoThemeEntries(dir: projectDirs.themes.first ?? ""),
                metadata: projectMetadata,
                overrides: projectOverrides.themes,
                baseDir: standardProjectBaseDir
            )
        }
    }

    private func collectFilesFromPaths(paths: [String], resourceType: ResourceType) -> [String] {
        var files: [String] = []
        for path in paths {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                files.append(contentsOf: collectResourceFiles(dir: path, resourceType: resourceType))
            } else {
                files.append(path)
            }
        }
        return files
    }

    func parseSource(_ source: String) -> ParsedSource {
        if source.hasPrefix("npm:") {
            let spec = String(source.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
            let parsed = parseNpmSpec(spec)
            return .npm(NpmSource(spec: spec, name: parsed.name, pinned: parsed.version != nil))
        }

        if isLocalPathLike(source) {
            return .local(LocalSource(path: source))
        }

        if source.hasPrefix("git:") || looksLikeGitUrl(source) {
            if let git = parseGitUrl(source) {
                return .git(git)
            }
        }

        return .local(LocalSource(path: source))
    }

    private func isLocalPathLike(_ input: String) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "~" || trimmed.hasPrefix("~/") || trimmed.hasPrefix("~") {
            return true
        }
        if trimmed.hasPrefix(".") || trimmed.hasPrefix("/") {
            return true
        }
        // Windows-style absolute paths (best-effort)
        if trimmed.count >= 3 {
            let chars = Array(trimmed)
            if chars[1] == ":", (chars[2] == "/" || chars[2] == "\\") {
                return true
            }
        }
        if trimmed.hasPrefix("\\\\") {
            return true
        }
        return false
    }

    private func looksLikeGitUrl(_ input: String) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("https://") ||
            trimmed.hasPrefix("http://") ||
            trimmed.hasPrefix("ssh://") ||
            trimmed.hasPrefix("git://")
    }

    func parseGitUrl(_ source: String) -> GitSource? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasGitPrefix = trimmed.hasPrefix("git:")
        let raw = hasGitPrefix ? String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines) : trimmed
        if !hasGitPrefix {
            guard raw.hasPrefix("https://") || raw.hasPrefix("http://") || raw.hasPrefix("ssh://") || raw.hasPrefix("git://") else {
                return nil
            }
        }

        let split = splitGitRef(raw)
        let repoWithoutRef = split.repo
        let ref = split.ref

        if repoWithoutRef.hasPrefix("git@"), let colonIndex = repoWithoutRef.firstIndex(of: ":") {
            let host = String(repoWithoutRef[repoWithoutRef.index(repoWithoutRef.startIndex, offsetBy: 4)..<colonIndex])
            let path = String(repoWithoutRef[repoWithoutRef.index(after: colonIndex)...])
            let normalizedPath = path.replacingOccurrences(of: ".git", with: "")
            return GitSource(repo: repoWithoutRef, host: host, path: normalizedPath, ref: ref, pinned: ref != nil)
        }

        if repoWithoutRef.contains("://"), let url = URL(string: repoWithoutRef), let host = url.host {
            let rawPath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let normalizedPath = rawPath.replacingOccurrences(of: ".git", with: "")
            guard !normalizedPath.isEmpty else { return nil }
            var repo = repoWithoutRef
            if repo.hasSuffix("/") { repo.removeLast() }
            return GitSource(repo: repo, host: host, path: normalizedPath, ref: ref, pinned: ref != nil)
        }

        let parts = repoWithoutRef.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }
        let host = String(parts[0])
        guard host.contains(".") || host == "localhost" else { return nil }
        let normalizedPath = String(parts[1]).replacingOccurrences(of: ".git", with: "")
        let repo = "https://\(repoWithoutRef)"
        return GitSource(repo: repo, host: host, path: normalizedPath, ref: ref, pinned: ref != nil)
    }

    private func splitGitRef(_ url: String) -> (repo: String, ref: String?) {
        if url.hasPrefix("git@"), let colonIndex = url.firstIndex(of: ":") {
            let hostPart = String(url[..<colonIndex])
            let pathPart = String(url[url.index(after: colonIndex)...])
            if let atIndex = pathPart.firstIndex(of: "@") {
                let repoPath = String(pathPart[..<atIndex])
                let ref = String(pathPart[pathPart.index(after: atIndex)...])
                if !repoPath.isEmpty && !ref.isEmpty {
                    return (repo: "\(hostPart):\(repoPath)", ref: ref)
                }
            }
            return (repo: url, ref: nil)
        }

        if url.contains("://"), let components = URLComponents(string: url) {
            let path = components.percentEncodedPath
            if let atIndex = path.firstIndex(of: "@") {
                var updated = components
                let repoPath = String(path[..<atIndex])
                let ref = String(path[path.index(after: atIndex)...])
                if !repoPath.isEmpty && !ref.isEmpty {
                    updated.percentEncodedPath = repoPath
                    let repo = updated.url?.absoluteString ?? url
                    return (repo: repo, ref: ref)
                }
            }
            return (repo: url, ref: nil)
        }

        if let slashIndex = url.firstIndex(of: "/") {
            let host = String(url[..<slashIndex])
            let pathPart = String(url[url.index(after: slashIndex)...])
            if let atIndex = pathPart.firstIndex(of: "@") {
                let repoPath = String(pathPart[..<atIndex])
                let ref = String(pathPart[pathPart.index(after: atIndex)...])
                if !repoPath.isEmpty && !ref.isEmpty {
                    return (repo: "\(host)/\(repoPath)", ref: ref)
                }
            }
        }

        return (repo: url, ref: nil)
    }

    func getPackageIdentity(_ source: String) -> String {
        let parsed = parseSource(source)
        switch parsed {
        case .npm(let npm):
            return "npm:\(npm.name)"
        case .git(let git):
            return "git:\(git.host)/\(git.path)"
        case .local(let local):
            return "local:\(resolvePath(local.path))"
        }
    }

    public func addSourceToSettings(_ source: String, local: Bool) -> Bool {
        let scope = local ? "project" : "user"
        let currentSettings = local ? settingsManager.getProjectSettings() : settingsManager.getGlobalSettings()
        let currentPackages = currentSettings.packages ?? []

        let normalizedSource = normalizePackageSourceForSettings(source, scope: scope)
        let exists = currentPackages.contains { packageSourcesMatch($0, source, scope: scope) }
        if exists {
            return false
        }

        let nextPackages = currentPackages + [.simple(normalizedSource)]
        if local {
            settingsManager.setProjectPackages(nextPackages)
        } else {
            settingsManager.setPackages(nextPackages)
        }
        return true
    }

    public func removeSourceFromSettings(_ source: String, local: Bool) -> Bool {
        let scope = local ? "project" : "user"
        let currentSettings = local ? settingsManager.getProjectSettings() : settingsManager.getGlobalSettings()
        let currentPackages = currentSettings.packages ?? []
        let nextPackages = currentPackages.filter { !packageSourcesMatch($0, source, scope: scope) }
        let changed = nextPackages.count != currentPackages.count
        if !changed {
            return false
        }

        if local {
            settingsManager.setProjectPackages(nextPackages)
        } else {
            settingsManager.setPackages(nextPackages)
        }
        return true
    }

    private func getSourceMatchKeyForInput(_ source: String) -> String {
        let parsed = parseSource(source)
        switch parsed {
        case .npm(let npm):
            return "npm:\(npm.name)"
        case .git(let git):
            return "git:\(git.host)/\(git.path)"
        case .local(let local):
            return "local:\(resolvePath(local.path))"
        }
    }

    private func getSourceMatchKeyForSettings(_ source: String, scope: String) -> String {
        let parsed = parseSource(source)
        switch parsed {
        case .npm(let npm):
            return "npm:\(npm.name)"
        case .git(let git):
            return "git:\(git.host)/\(git.path)"
        case .local(let local):
            let baseDir = getBaseDirForScope(scope)
            return "local:\(resolvePathFromBase(local.path, baseDir: baseDir))"
        }
    }

    private func packageSourcesMatch(_ existing: PackageSource, _ inputSource: String, scope: String) -> Bool {
        let left = getSourceMatchKeyForSettings(packageSourceString(existing), scope: scope)
        let right = getSourceMatchKeyForInput(inputSource)
        return left == right
    }

    private func normalizePackageSourceForSettings(_ source: String, scope: String) -> String {
        let parsed = parseSource(source)
        switch parsed {
        case .local(let local):
            let baseDir = getBaseDirForScope(scope)
            let resolved = resolvePath(local.path)
            let relative = relativePath(from: baseDir, to: resolved)
            if relative.isEmpty {
                return "."
            }
            if relative == "." || relative.hasPrefix("./") || relative.hasPrefix("../") {
                return relative
            }
            return "./\(relative)"
        case .npm, .git:
            return source
        }
    }

    private func getBaseDirForScope(_ scope: String) -> String {
        if scope == "project" {
            return URL(fileURLWithPath: cwd).appendingPathComponent(CONFIG_DIR_NAME).path
        }
        return agentDir
    }

    private func relativePath(from baseDir: String, to targetPath: String) -> String {
        let baseURL = URL(fileURLWithPath: baseDir).standardized
        let targetURL = URL(fileURLWithPath: targetPath).standardized
        let baseComponents = baseURL.pathComponents
        let targetComponents = targetURL.pathComponents

        var index = 0
        while index < min(baseComponents.count, targetComponents.count),
              baseComponents[index] == targetComponents[index] {
            index += 1
        }

        let upMoves = Array(repeating: "..", count: baseComponents.count - index)
        let downMoves = Array(targetComponents[index...])
        return (upMoves + downMoves).joined(separator: "/")
    }

    private func packageSourceString(_ pkg: PackageSource) -> String {
        switch pkg {
        case .simple(let value):
            return value
        case .filtered(let value):
            return value.source
        }
    }

    private func dedupePackages(_ packages: [(PackageSource, String)]) -> [(PackageSource, String)] {
        var seen: [String: (PackageSource, String)] = [:]
        for entry in packages {
            let identity = getPackageIdentity(entry.0.source)
            if let existing = seen[identity] {
                if entry.1 == "project" && existing.1 == "user" {
                    seen[identity] = entry
                }
            } else {
                seen[identity] = entry
            }
        }
        return Array(seen.values)
    }

    // MARK: - Helpers

    private func runCommand(_ command: String, _ args: [String], cwd: String) async throws -> ExecResult {
        if let override = commandRunnerOverride.withLock({ $0 }) {
            return try await override(command, args, cwd)
        }
        #if canImport(UIKit)
        throw PackageManagerError.unsupported("Command execution not available")
        #else
        let result = await execCommand(command, args, cwd)
        if result.code != 0 {
            throw PackageManagerError.commandFailed("\(command) \(args.joined(separator: " ")) failed with code \(result.code)")
        }
        return result
        #endif
    }

    private func runCommandSync(_ command: String, _ args: [String]) -> String {
        let process = Process()
        if command.contains("/") {
            process.executableURL = URL(fileURLWithPath: command)
            process.arguments = args
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command] + args
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return ""
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }

    private func sha256(_ input: String) -> String {
        let data = Data(input.utf8)
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
        #else
        return String(data.hashValue)
        #endif
    }
}

private enum PackageManagerError: LocalizedError {
    case unsupported(String)
    case missing(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let message):
            return message
        case .missing(let message):
            return message
        case .commandFailed(let message):
            return message
        }
    }
}

private enum ResourceType: String, CaseIterable {
    case extensions
    case skills
    case prompts
    case themes
}

private struct SettingsPaths {
    var extensions: [String]
    var skills: [String]
    var prompts: [String]
    var themes: [String]
}

private final class ResourceAccumulator {
    struct Entry {
        var metadata: PathMetadata
        var enabled: Bool
    }

    var extensions: [String: Entry] = [:]
    var skills: [String: Entry] = [:]
    var prompts: [String: Entry] = [:]
    var themes: [String: Entry] = [:]

    func add(resourceType: ResourceType, path: String, metadata: PathMetadata, enabled: Bool) {
        guard !path.isEmpty else { return }
        switch resourceType {
        case .extensions:
            if extensions[path] == nil { extensions[path] = Entry(metadata: metadata, enabled: enabled) }
        case .skills:
            if skills[path] == nil { skills[path] = Entry(metadata: metadata, enabled: enabled) }
        case .prompts:
            if prompts[path] == nil { prompts[path] = Entry(metadata: metadata, enabled: enabled) }
        case .themes:
            if themes[path] == nil { themes[path] = Entry(metadata: metadata, enabled: enabled) }
        }
    }

    func toResolvedPaths() -> ResolvedPaths {
        func build(_ map: [String: Entry]) -> [ResolvedResource] {
            map.map { ResolvedResource(path: $0.key, enabled: $0.value.enabled, metadata: $0.value.metadata) }
        }
        return ResolvedPaths(
            extensions: build(extensions),
            skills: build(skills),
            prompts: build(prompts),
            themes: build(themes)
        )
    }
}

private struct PiManifest {
    var extensions: [String]?
    var skills: [String]?
    var prompts: [String]?
    var themes: [String]?

    init(raw: [String: Any]) {
        extensions = raw["extensions"] as? [String]
        skills = raw["skills"] as? [String]
        prompts = raw["prompts"] as? [String]
        themes = raw["themes"] as? [String]
    }

    func entries(for resourceType: ResourceType) -> [String]? {
        switch resourceType {
        case .extensions:
            return extensions
        case .skills:
            return skills
        case .prompts:
            return prompts
        case .themes:
            return themes
        }
    }
}

struct NpmSource {
    var spec: String
    var name: String
    var pinned: Bool
}

struct GitSource {
    var repo: String
    var host: String
    var path: String
    var ref: String?
    var pinned: Bool
}

struct LocalSource {
    var path: String
}

enum ParsedSource {
    case npm(NpmSource)
    case git(GitSource)
    case local(LocalSource)
}

private final class IgnoreMatcher {
    private struct Rule {
        let pattern: String
        let negated: Bool
    }

    private var rules: [Rule] = []

    func add(patterns: [String]) {
        for pattern in patterns {
            if pattern.hasPrefix("!") {
                rules.append(Rule(pattern: String(pattern.dropFirst()), negated: true))
            } else {
                rules.append(Rule(pattern: pattern, negated: false))
            }
        }
    }

    func ignores(_ path: String) -> Bool {
        var ignored = false
        for rule in rules {
            if matchesGlob(path, rule.pattern) {
                ignored = !rule.negated
            }
        }
        return ignored
    }
}

private let ignoreFileNames = [".gitignore", ".ignore", ".fdignore"]

private func toPosixPath(_ path: String) -> String {
    path.replacingOccurrences(of: "\\", with: "/")
}

/// Resolves symlinks in a path to get the canonical path.
/// Handles /var -> /private/var on macOS.
private func resolveRealPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

private func prefixIgnorePattern(_ line: String, prefix: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if trimmed.hasPrefix("#") && !trimmed.hasPrefix("\\#") {
        return nil
    }

    var pattern = line
    var negated = false

    if pattern.hasPrefix("!") {
        negated = true
        pattern = String(pattern.dropFirst())
    } else if pattern.hasPrefix("\\!") {
        pattern = String(pattern.dropFirst())
    }

    if pattern.hasPrefix("/") {
        pattern = String(pattern.dropFirst())
    }

    let prefixed = prefix.isEmpty ? pattern : prefix + pattern
    return negated ? "!\(prefixed)" : prefixed
}

private func addIgnoreRules(_ ig: IgnoreMatcher, dir: String, rootDir: String) {
    let relativeDir = URL(fileURLWithPath: dir).path.replacingOccurrences(of: rootDir, with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let prefix = relativeDir.isEmpty ? "" : "\(toPosixPath(relativeDir))/"

    for name in ignoreFileNames {
        let ignorePath = URL(fileURLWithPath: dir).appendingPathComponent(name).path
        guard let content = try? String(contentsOfFile: ignorePath, encoding: .utf8) else { continue }
        let patterns = content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { prefixIgnorePattern(String($0), prefix: prefix) }
        if !patterns.isEmpty {
            ig.add(patterns: patterns)
        }
    }
}

private func isPattern(_ value: String) -> Bool {
    value.hasPrefix("!") || value.hasPrefix("+") || value.hasPrefix("-") || value.contains("*") || value.contains("?")
}

private func splitPatterns(_ entries: [String]) -> (plain: [String], patterns: [String]) {
    var plain: [String] = []
    var patterns: [String] = []
    for entry in entries {
        if isPattern(entry) {
            patterns.append(entry)
        } else {
            plain.append(entry)
        }
    }
    return (plain, patterns)
}

private func collectFiles(
    dir: String,
    filePattern: (String) -> Bool,
    skipNodeModules: Bool = true,
    ignoreMatcher: IgnoreMatcher? = nil,
    rootDir: String? = nil
) -> [String] {
    guard FileManager.default.fileExists(atPath: dir) else { return [] }
    let root = rootDir ?? dir
    let ig = ignoreMatcher ?? IgnoreMatcher()
    addIgnoreRules(ig, dir: dir, rootDir: root)

    var files: [String] = []
    guard let entries = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: []) else {
        return files
    }

    for entry in entries {
        let name = entry.lastPathComponent
        if name.hasPrefix(".") { continue }
        if skipNodeModules && name == "node_modules" { continue }

        let fullPath = entry.path
        var isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        var isFile = (try? entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
        if (try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false {
            var dirFlag: ObjCBool = false
            if FileManager.default.fileExists(atPath: fullPath, isDirectory: &dirFlag) {
                isDir = dirFlag.boolValue
                isFile = !dirFlag.boolValue
            } else {
                continue
            }
        }

        let relative = toPosixPath(URL(fileURLWithPath: fullPath).path.replacingOccurrences(of: root + "/", with: ""))
        let ignorePath = isDir ? relative + "/" : relative
        if ig.ignores(ignorePath) { continue }

        if isDir {
            files.append(contentsOf: collectFiles(dir: fullPath, filePattern: filePattern, skipNodeModules: skipNodeModules, ignoreMatcher: ig, rootDir: root))
        } else if isFile, filePattern(name) {
            files.append(fullPath)
        }
    }

    return files
}

private func collectSkillEntries(
    dir: String,
    includeRootFiles: Bool = true,
    ignoreMatcher: IgnoreMatcher? = nil,
    rootDir: String? = nil
) -> [String] {
    guard FileManager.default.fileExists(atPath: dir) else { return [] }
    let root = rootDir ?? dir
    let ig = ignoreMatcher ?? IgnoreMatcher()
    addIgnoreRules(ig, dir: dir, rootDir: root)

    var entries: [String] = []
    guard let dirEntries = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: []) else {
        return entries
    }

    for entry in dirEntries {
        let name = entry.lastPathComponent
        if name.hasPrefix(".") { continue }
        if name == "node_modules" { continue }

        let fullPath = entry.path
        var isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        var isFile = (try? entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
        if (try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false {
            var dirFlag: ObjCBool = false
            if FileManager.default.fileExists(atPath: fullPath, isDirectory: &dirFlag) {
                isDir = dirFlag.boolValue
                isFile = !dirFlag.boolValue
            } else {
                continue
            }
        }

        let relative = toPosixPath(URL(fileURLWithPath: fullPath).path.replacingOccurrences(of: root + "/", with: ""))
        let ignorePath = isDir ? relative + "/" : relative
        if ig.ignores(ignorePath) { continue }

        if isDir {
            entries.append(contentsOf: collectSkillEntries(dir: fullPath, includeRootFiles: false, ignoreMatcher: ig, rootDir: root))
        } else if isFile {
            let isRootMd = includeRootFiles && name.hasSuffix(".md")
            let isSkillMd = !includeRootFiles && name == "SKILL.md"
            if isRootMd || isSkillMd {
                entries.append(fullPath)
            }
        }
    }

    return entries
}

private func collectAutoSkillEntries(dir: String) -> [String] {
    collectSkillEntries(dir: dir)
}

private func findGitRepoRoot(startDir: String) -> String? {
    var dir = URL(fileURLWithPath: startDir).resolvingSymlinksInPath().path
    while true {
        if FileManager.default.fileExists(atPath: URL(fileURLWithPath: dir).appendingPathComponent(".git").path) {
            return dir
        }
        let parent = URL(fileURLWithPath: dir).deletingLastPathComponent().path
        if parent == dir {
            return nil
        }
        dir = parent
    }
}

private func collectAncestorAgentsSkillDirs(startDir: String) -> [String] {
    var result: [String] = []
    var dir = URL(fileURLWithPath: startDir).resolvingSymlinksInPath().path
    let gitRoot = findGitRepoRoot(startDir: dir)
    while true {
        result.append(URL(fileURLWithPath: dir).appendingPathComponent(".agents").appendingPathComponent("skills").path)
        if let gitRoot, dir == gitRoot {
            break
        }
        let parent = URL(fileURLWithPath: dir).deletingLastPathComponent().path
        if parent == dir {
            break
        }
        dir = parent
    }
    return result
}

private func collectAutoPromptEntries(dir: String) -> [String] {
    guard FileManager.default.fileExists(atPath: dir) else { return [] }
    let ig = IgnoreMatcher()
    addIgnoreRules(ig, dir: dir, rootDir: dir)

    var entries: [String] = []
    guard let dirEntries = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: []) else {
        return entries
    }

    for entry in dirEntries {
        let name = entry.lastPathComponent
        if name.hasPrefix(".") || name == "node_modules" { continue }
        let fullPath = entry.path
        var isFile = (try? entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
        if (try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false {
            var dirFlag: ObjCBool = false
            if FileManager.default.fileExists(atPath: fullPath, isDirectory: &dirFlag) {
                isFile = !dirFlag.boolValue
            } else {
                continue
            }
        }
        let relative = toPosixPath(URL(fileURLWithPath: fullPath).path.replacingOccurrences(of: dir + "/", with: ""))
        if ig.ignores(relative) { continue }
        if isFile && name.hasSuffix(".md") {
            entries.append(fullPath)
        }
    }

    return entries
}

private func collectAutoThemeEntries(dir: String) -> [String] {
    guard FileManager.default.fileExists(atPath: dir) else { return [] }
    let ig = IgnoreMatcher()
    addIgnoreRules(ig, dir: dir, rootDir: dir)

    var entries: [String] = []
    guard let dirEntries = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: []) else {
        return entries
    }

    for entry in dirEntries {
        let name = entry.lastPathComponent
        if name.hasPrefix(".") || name == "node_modules" { continue }
        let fullPath = entry.path
        var isFile = (try? entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
        if (try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false {
            var dirFlag: ObjCBool = false
            if FileManager.default.fileExists(atPath: fullPath, isDirectory: &dirFlag) {
                isFile = !dirFlag.boolValue
            } else {
                continue
            }
        }
        let relative = toPosixPath(URL(fileURLWithPath: fullPath).path.replacingOccurrences(of: dir + "/", with: ""))
        if ig.ignores(relative) { continue }
        if isFile && name.hasSuffix(".json") {
            entries.append(fullPath)
        }
    }

    return entries
}

private func resolveExtensionEntries(_ dir: String) -> [String]? {
    let packageJsonPath = URL(fileURLWithPath: dir).appendingPathComponent("package.json").path
    if FileManager.default.fileExists(atPath: packageJsonPath),
       let data = try? Data(contentsOf: URL(fileURLWithPath: packageJsonPath)),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let pi = json["pi"] as? [String: Any],
       let extensions = pi["extensions"] as? [String],
       !extensions.isEmpty {
        var entries: [String] = []
        for extPath in extensions {
            let resolved = URL(fileURLWithPath: dir).appendingPathComponent(extPath).path
            if FileManager.default.fileExists(atPath: resolved) {
                entries.append(resolved)
            }
        }
        if !entries.isEmpty {
            return entries
        }
    }

    let indexTs = URL(fileURLWithPath: dir).appendingPathComponent("index.ts").path
    let indexJs = URL(fileURLWithPath: dir).appendingPathComponent("index.js").path
    if FileManager.default.fileExists(atPath: indexTs) {
        return [indexTs]
    }
    if FileManager.default.fileExists(atPath: indexJs) {
        return [indexJs]
    }
    return nil
}

private func collectAutoExtensionEntries(dir: String) -> [String] {
    guard FileManager.default.fileExists(atPath: dir) else { return [] }
    let ig = IgnoreMatcher()
    addIgnoreRules(ig, dir: dir, rootDir: dir)

    var entries: [String] = []
    guard let dirEntries = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey], options: []) else {
        return entries
    }

    for entry in dirEntries {
        let name = entry.lastPathComponent
        if name.hasPrefix(".") || name == "node_modules" { continue }
        let fullPath = entry.path
        var isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        var isFile = (try? entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
        if (try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false {
            var dirFlag: ObjCBool = false
            if FileManager.default.fileExists(atPath: fullPath, isDirectory: &dirFlag) {
                isDir = dirFlag.boolValue
                isFile = !dirFlag.boolValue
            } else {
                continue
            }
        }

        let relative = toPosixPath(URL(fileURLWithPath: fullPath).path.replacingOccurrences(of: dir + "/", with: ""))
        let ignorePath = isDir ? relative + "/" : relative
        if ig.ignores(ignorePath) { continue }

        if isFile && (name.hasSuffix(".ts") || name.hasSuffix(".js")) {
            entries.append(fullPath)
        } else if isDir, let resolved = resolveExtensionEntries(fullPath) {
            entries.append(contentsOf: resolved)
        }
    }

    return entries
}

private func collectResourceFiles(dir: String, resourceType: ResourceType) -> [String] {
    switch resourceType {
    case .skills:
        return collectSkillEntries(dir: dir)
    case .extensions:
        return collectAutoExtensionEntries(dir: dir)
    case .prompts:
        return collectFiles(dir: dir, filePattern: { $0.hasSuffix(".md") })
    case .themes:
        return collectFiles(dir: dir, filePattern: { $0.hasSuffix(".json") })
    }
}

private func matchesAnyPattern(filePath: String, patterns: [String], baseDir: String) -> Bool {
    let rel = toPosixPath(URL(fileURLWithPath: filePath).path.replacingOccurrences(of: baseDir + "/", with: ""))
    let name = URL(fileURLWithPath: filePath).lastPathComponent
    let isSkillFile = name == "SKILL.md"
    let parentDir = isSkillFile ? URL(fileURLWithPath: filePath).deletingLastPathComponent().path : nil
    let parentRel = isSkillFile ? toPosixPath(URL(fileURLWithPath: parentDir!).path.replacingOccurrences(of: baseDir + "/", with: "")) : nil
    let parentName = isSkillFile ? URL(fileURLWithPath: parentDir!).lastPathComponent : nil

    return patterns.contains { pattern in
        matchesGlob(rel, pattern) || matchesGlob(name, pattern) || matchesGlob(filePath, pattern) || (isSkillFile && (
            matchesGlob(parentRel ?? "", pattern) || matchesGlob(parentName ?? "", pattern) || matchesGlob(parentDir ?? "", pattern)
        ))
    }
}

private func normalizeExactPattern(_ pattern: String) -> String {
    if pattern.hasPrefix("./") || pattern.hasPrefix(".\\") {
        return String(pattern.dropFirst(2))
    }
    return pattern
}

private func matchesAnyExactPattern(filePath: String, patterns: [String], baseDir: String) -> Bool {
    guard !patterns.isEmpty else { return false }
    let rel = toPosixPath(URL(fileURLWithPath: filePath).path.replacingOccurrences(of: baseDir + "/", with: ""))
    let name = URL(fileURLWithPath: filePath).lastPathComponent
    let isSkillFile = name == "SKILL.md"
    let parentDir = isSkillFile ? URL(fileURLWithPath: filePath).deletingLastPathComponent().path : nil
    let parentRel = isSkillFile ? toPosixPath(URL(fileURLWithPath: parentDir!).path.replacingOccurrences(of: baseDir + "/", with: "")) : nil

    return patterns.contains { pattern in
        let normalized = normalizeExactPattern(pattern)
        if normalized == rel || normalized == filePath { return true }
        if isSkillFile {
            return normalized == parentRel || normalized == parentDir
        }
        return false
    }
}

private func getOverridePatterns(_ entries: [String]) -> [String] {
    entries.filter { $0.hasPrefix("!") || $0.hasPrefix("+") || $0.hasPrefix("-") }
}

private func isEnabledByOverrides(filePath: String, patterns: [String], baseDir: String) -> Bool {
    let overrides = getOverridePatterns(patterns)
    let excludes = overrides.filter { $0.hasPrefix("!") }.map { String($0.dropFirst()) }
    let forceIncludes = overrides.filter { $0.hasPrefix("+") }.map { String($0.dropFirst()) }
    let forceExcludes = overrides.filter { $0.hasPrefix("-") }.map { String($0.dropFirst()) }

    var enabled = true
    if !excludes.isEmpty && matchesAnyPattern(filePath: filePath, patterns: excludes, baseDir: baseDir) {
        enabled = false
    }
    if !forceIncludes.isEmpty && matchesAnyExactPattern(filePath: filePath, patterns: forceIncludes, baseDir: baseDir) {
        enabled = true
    }
    if !forceExcludes.isEmpty && matchesAnyExactPattern(filePath: filePath, patterns: forceExcludes, baseDir: baseDir) {
        enabled = false
    }
    return enabled
}

private func applyPatterns(allPaths: [String], patterns: [String], baseDir: String) -> Set<String> {
    var includes: [String] = []
    var excludes: [String] = []
    var forceIncludes: [String] = []
    var forceExcludes: [String] = []

    for pattern in patterns {
        if pattern.hasPrefix("+") {
            forceIncludes.append(String(pattern.dropFirst()))
        } else if pattern.hasPrefix("-") {
            forceExcludes.append(String(pattern.dropFirst()))
        } else if pattern.hasPrefix("!") {
            excludes.append(String(pattern.dropFirst()))
        } else {
            includes.append(pattern)
        }
    }

    var result: [String]
    if includes.isEmpty {
        result = allPaths
    } else {
        result = allPaths.filter { matchesAnyPattern(filePath: $0, patterns: includes, baseDir: baseDir) }
    }

    if !excludes.isEmpty {
        result = result.filter { !matchesAnyPattern(filePath: $0, patterns: excludes, baseDir: baseDir) }
    }

    if !forceIncludes.isEmpty {
        for file in allPaths where !result.contains(file) {
            if matchesAnyExactPattern(filePath: file, patterns: forceIncludes, baseDir: baseDir) {
                result.append(file)
            }
        }
    }

    if !forceExcludes.isEmpty {
        result = result.filter { !matchesAnyExactPattern(filePath: $0, patterns: forceExcludes, baseDir: baseDir) }
    }

    return Set(result)
}

private extension Settings {
    func paths(for resourceType: ResourceType) -> [String] {
        switch resourceType {
        case .extensions:
            return extensions ?? []
        case .skills:
            return skillPaths ?? []
        case .prompts:
            return prompts ?? []
        case .themes:
            return themes ?? []
        }
    }
}

private extension PackageFilter {
    func patterns(for resourceType: ResourceType) -> [String]? {
        switch resourceType {
        case .extensions:
            return extensions
        case .skills:
            return skills
        case .prompts:
            return prompts
        case .themes:
            return themes
        }
    }
}
