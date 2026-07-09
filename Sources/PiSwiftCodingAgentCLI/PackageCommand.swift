import Foundation
import PiSwiftCodingAgent

private enum PackageCommand: String {
    case install
    case remove
    case update
    case list
}

private struct PackageCommandOptions {
    var command: PackageCommand
    var source: String?
    var local: Bool
    var help: Bool
    var invalidOption: String?
}

/// SAFETY: the optional exit code is read and written only while holding `lock`;
/// values are copied `Int32`s.
private final class PackageCommandExitCodeStore: @unchecked Sendable {
    private let lock = NSLock()
    private var code: Int32?

    func consume() -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        defer { code = nil }
        return code
    }

    func set(_ value: Int32) {
        lock.lock()
        code = value
        lock.unlock()
    }
}

private let packageCommandExitCodeStore = PackageCommandExitCodeStore()

@discardableResult
func consumePackageCommandExitCode() -> Int32? {
    packageCommandExitCodeStore.consume()
}

private func setPackageCommandExitCode(_ code: Int32) {
    packageCommandExitCodeStore.set(code)
}

private func packageCommandUsage(_ command: PackageCommand) -> String {
    switch command {
    case .install:
        return "\(APP_NAME) install <source> [-l]"
    case .remove:
        return "\(APP_NAME) remove <source> [-l]"
    case .update:
        return "\(APP_NAME) update [source]"
    case .list:
        return "\(APP_NAME) list"
    }
}

private func printPackageCommandHelp(_ command: PackageCommand) {
    print("Usage:")
    print("  \(packageCommandUsage(command))")
}

func handlePackageCommand(
    _ args: [String],
    approve: Bool = false,
    noApprove: Bool = false,
    noExtensions: Bool = false,
    offline: Bool = false
) async -> Bool {
    _ = consumePackageCommandExitCode()
    guard let options = parsePackageCommand(args) else { return false }

    if options.help {
        printPackageCommandHelp(options.command)
        return true
    }

    if let invalidOption = options.invalidOption {
        fputs("Unknown option \(invalidOption) for \"\(options.command.rawValue)\".\n", stderr)
        fputs("Use \"\(APP_NAME) --help\" or \"\(packageCommandUsage(options.command))\".\n", stderr)
        setPackageCommandExitCode(1)
        return true
    }

    if (options.command == .install || options.command == .remove),
       options.source == nil || options.source?.isEmpty == true {
        fputs("Missing \(options.command.rawValue) source.\n", stderr)
        fputs("Usage: \(packageCommandUsage(options.command))\n", stderr)
        setPackageCommandExitCode(1)
        return true
    }

    if offline && (options.command == .install || options.command == .update) {
        let action = options.command == .install ? "install" : "update"
        fputs("Offline mode is enabled; package \(action) is unavailable.\n", stderr)
        setPackageCommandExitCode(1)
        return true
    }

    let cwd = FileManager.default.currentDirectoryPath
    let agentDir = getAgentDir()
    let authStorage = AuthStorage.create(getAuthPath())
    let modelRegistry = ModelRegistry(authStorage, agentDir)
    let trustChoice = projectTrustChoice(approve: approve, noApprove: noApprove)
    let trustContext = await resolveProjectTrustForCLI(
        cwd: cwd,
        agentDir: agentDir,
        modelRegistry: modelRegistry,
        eventBus: createEventBus(),
        choice: trustChoice,
        persistChoice: trustChoice != nil,
        noExtensions: noExtensions,
        mode: .print,
        hasUI: false
    )
    let settingsManager = trustContext.settingsManager
    for error in settingsManager.drainErrors() {
        fputs("Warning (package command, \(error.scope) settings): \(error.message)\n", stderr)
    }
    if options.local && !trustContext.trust.trusted {
        fputs("Project package changes require a trusted project. Re-run with --approve to allow project-local package settings.\n", stderr)
        setPackageCommandExitCode(1)
        return true
    }
    let packageManager = DefaultPackageManager(
        cwd: cwd,
        agentDir: agentDir,
        settingsManager: settingsManager,
        projectTrusted: trustContext.trust.trusted,
        offline: offline
    )

    packageManager.setProgressCallback { event in
        switch event.type {
        case "start":
            if let message = event.message {
                fputs("\(message)\n", stdout)
            }
        case "error":
            if let message = event.message {
                fputs("Error: \(message)\n", stderr)
            }
        default:
            break
        }
    }

    do {
        switch options.command {
        case .install:
            guard let source = options.source, !source.isEmpty else {
                fputs("Missing install source.\n", stderr)
                setPackageCommandExitCode(1)
                return true
            }
            try await packageManager.install(source, options: PackageResolveOptions(local: options.local))
            _ = packageManager.addSourceToSettings(source, local: options.local)
            print("Installed \(source)")
        case .remove:
            guard let source = options.source, !source.isEmpty else {
                fputs("Missing remove source.\n", stderr)
                setPackageCommandExitCode(1)
                return true
            }
            try await packageManager.remove(source, options: PackageResolveOptions(local: options.local))
            let removed = packageManager.removeSourceFromSettings(source, local: options.local)
            if !removed {
                fputs("No matching package found for \(source).\n", stderr)
                setPackageCommandExitCode(1)
                return true
            }
            print("Removed \(source)")
        case .list:
            let globalPackages = settingsManager.getGlobalSettings().packages ?? []
            let projectPackages = settingsManager.getProjectSettings().packages ?? []
            if globalPackages.isEmpty && projectPackages.isEmpty {
                print("No packages installed.")
                return true
            }

            func formatPackage(_ pkg: PackageSource, scope: String) {
                let source = packageSourceString(pkg)
                let display = isFiltered(pkg) ? "\(source) (filtered)" : source
                print("  \(display)")
                if let path = packageManager.getInstalledPath(source, scope: scope) {
                    print("    \(path)")
                }
            }

            if !globalPackages.isEmpty {
                print("User packages:")
                for pkg in globalPackages {
                    formatPackage(pkg, scope: "user")
                }
            }

            if !projectPackages.isEmpty {
                if !globalPackages.isEmpty { print("") }
                print("Project packages:")
                for pkg in projectPackages {
                    formatPackage(pkg, scope: "project")
                }
            }
        case .update:
            try await packageManager.update(options.source)
            if let source = options.source, !source.isEmpty {
                print("Updated \(source)")
            } else {
                print("Updated packages")
            }
        }
    } catch {
        fputs("Error: \(error.localizedDescription)\n", stderr)
        setPackageCommandExitCode(1)
    }

    return true
}

private func parsePackageCommand(_ args: [String]) -> PackageCommandOptions? {
    guard let command = args.first else { return nil }
    // "uninstall" is an alias for "remove"
    let normalizedCommand = command == "uninstall" ? "remove" : command
    guard let parsed = PackageCommand(rawValue: normalizedCommand) else {
        return nil
    }

    var local = false
    var help = false
    var invalidOption: String?
    var source: String?
    for arg in args.dropFirst() {
        if arg == "-h" || arg == "--help" {
            help = true
            continue
        }
        if arg == "-l" || arg == "--local" {
            if parsed == .install || parsed == .remove {
                local = true
            } else if invalidOption == nil {
                invalidOption = arg
            }
            continue
        }
        if arg.hasPrefix("-") {
            if invalidOption == nil {
                invalidOption = arg
            }
            continue
        }
        if source == nil {
            source = arg
        }
    }

    return PackageCommandOptions(
        command: parsed,
        source: source,
        local: local,
        help: help,
        invalidOption: invalidOption
    )
}

private enum PackageSourceAction {
    case add
    case remove
}

private func updatePackageSources(
    _ settingsManager: SettingsManager,
    source: String,
    local: Bool,
    action: PackageSourceAction
) {
    let currentSettings = local ? settingsManager.getProjectSettings() : settingsManager.getGlobalSettings()
    let currentPackages = currentSettings.packages ?? []

    let nextPackages: [PackageSource]
    switch action {
    case .add:
        let exists = currentPackages.contains { packageSourcesMatch($0, source) }
        nextPackages = exists ? currentPackages : currentPackages + [.simple(source)]
    case .remove:
        nextPackages = currentPackages.filter { !packageSourcesMatch($0, source) }
    }

    if local {
        settingsManager.setProjectPackages(nextPackages)
    } else {
        settingsManager.setPackages(nextPackages)
    }
}

private func packageSourceString(_ pkg: PackageSource) -> String {
    switch pkg {
    case .simple(let value):
        return value
    case .filtered(let value):
        return value.source
    }
}

private func isFiltered(_ pkg: PackageSource) -> Bool {
    if case .filtered = pkg { return true }
    return false
}

private func packageSourcesMatch(_ a: PackageSource, _ b: String) -> Bool {
    let aSource = packageSourceString(a)
    return sourcesMatch(aSource, b)
}

private func sourcesMatch(_ a: String, _ b: String) -> Bool {
    let left = normalizePackageSource(a)
    let right = normalizePackageSource(b)
    return left.type == right.type && left.key == right.key
}

private func normalizePackageSource(_ source: String) -> (type: String, key: String) {
    if source.hasPrefix("npm:") {
        let spec = source.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines)
        let (name, _) = parseNpmSpec(String(spec))
        return ("npm", name)
    }
    if source.hasPrefix("git:") {
        let repo = source.dropFirst(4).split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let key = String(repo)
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: ".git", with: "")
        return ("git", key)
    }
    if source.hasPrefix("https://") || source.hasPrefix("http://") {
        let repo = source.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let key = String(repo)
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: ".git", with: "")
        return ("git", key)
    }
    return ("local", source)
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
