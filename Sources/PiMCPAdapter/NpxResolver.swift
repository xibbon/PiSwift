import Foundation

// MARK: - NPX Resolution Types

public struct NpxResolution: Sendable {
    public var binPath: String
    public var isJs: Bool
    public var extraArgs: [String]

    public init(binPath: String, isJs: Bool, extraArgs: [String] = []) {
        self.binPath = binPath
        self.isJs = isJs
        self.extraArgs = extraArgs
    }
}

// MARK: - Main Resolver

public func resolveNpxBinary(command: String, args: [String]) async -> NpxResolution? {
    let lowerCommand = command.lowercased()
    let parsed: (packageSpec: String, binName: String?, extraArgs: [String])

    if lowerCommand == "npx" || lowerCommand.hasSuffix("/npx") {
        guard let p = parseNpxArgs(args) else { return nil }
        parsed = p
    } else if lowerCommand == "npm" || lowerCommand.hasSuffix("/npm") {
        guard let p = parseNpmExecArgs(args) else { return nil }
        parsed = p
    } else {
        return nil
    }

    // Try resolving from npm cache
    if let resolved = resolveFromNpmCache(packageSpec: parsed.packageSpec, binName: parsed.binName) {
        return NpxResolution(binPath: resolved.binPath, isJs: resolved.isJs, extraArgs: parsed.extraArgs)
    }

    // Force-populate via npm exec
    if let resolved = await forcePopulate(packageSpec: parsed.packageSpec, binName: parsed.binName) {
        return NpxResolution(binPath: resolved.binPath, isJs: resolved.isJs, extraArgs: parsed.extraArgs)
    }

    return nil
}

// MARK: - Arg Parsing

func parseNpxArgs(_ args: [String]) -> (packageSpec: String, binName: String?, extraArgs: [String])? {
    var i = 0
    var packageSpec: String?
    var extraArgs: [String] = []
    var afterSeparator = false

    while i < args.count {
        let arg = args[i]

        if afterSeparator {
            extraArgs.append(arg)
            i += 1
            continue
        }

        if arg == "--" {
            afterSeparator = true
            i += 1
            continue
        }

        if arg == "-y" || arg == "--yes" {
            i += 1
            continue
        }

        if arg == "-p" || arg == "--package" {
            i += 1
            if i < args.count {
                packageSpec = args[i]
            }
            i += 1
            continue
        }

        if arg.hasPrefix("--package=") {
            packageSpec = String(arg.dropFirst("--package=".count))
            i += 1
            continue
        }

        // Once we have the package spec, everything else is extra args
        if packageSpec != nil {
            extraArgs.append(arg)
            i += 1
            continue
        }

        if arg.hasPrefix("-") {
            i += 1
            continue
        }

        // First positional arg is the package/binary
        packageSpec = arg
        i += 1
    }

    guard let spec = packageSpec else { return nil }
    // If spec contains @scope/, the bin name might differ from the package name
    let binName = extractBinName(from: spec)
    return (spec, binName, extraArgs)
}

func parseNpmExecArgs(_ args: [String]) -> (packageSpec: String, binName: String?, extraArgs: [String])? {
    // npm exec --yes --package <spec> -- <bin> <args>
    guard args.first == "exec" else { return nil }

    var i = 1
    var packageSpec: String?
    var extraArgs: [String] = []
    var afterSeparator = false

    while i < args.count {
        let arg = args[i]

        if afterSeparator {
            extraArgs.append(arg)
            i += 1
            continue
        }

        if arg == "--" {
            afterSeparator = true
            i += 1
            continue
        }

        if arg == "--yes" || arg == "-y" {
            i += 1
            continue
        }

        if arg == "--package" || arg == "-p" {
            i += 1
            if i < args.count { packageSpec = args[i] }
            i += 1
            continue
        }

        if arg.hasPrefix("--package=") {
            packageSpec = String(arg.dropFirst("--package=".count))
            i += 1
            continue
        }

        i += 1
    }

    guard let spec = packageSpec else { return nil }
    let binName = extraArgs.isEmpty ? nil : extraArgs.removeFirst()
    return (spec, binName, extraArgs)
}

private func extractBinName(from spec: String) -> String? {
    // Remove version specifier (e.g., @scope/package@1.2.3 -> @scope/package)
    let withoutVersion: String
    if spec.hasPrefix("@") {
        // Scoped package: @scope/name@version
        if let slashIdx = spec.firstIndex(of: "/") {
            let afterSlash = spec[spec.index(after: slashIdx)...]
            if let atIdx = afterSlash.lastIndex(of: "@") {
                withoutVersion = String(spec[spec.startIndex..<atIdx])
            } else {
                withoutVersion = spec
            }
        } else {
            withoutVersion = spec
        }
    } else if let atIdx = spec.lastIndex(of: "@") {
        withoutVersion = String(spec[spec.startIndex..<atIdx])
    } else {
        withoutVersion = spec
    }

    // Return the last path component
    if withoutVersion.contains("/") {
        return withoutVersion.components(separatedBy: "/").last
    }
    return nil
}

// MARK: - NPM Cache Probing

private func resolveFromNpmCache(packageSpec: String, binName: String?) -> (binPath: String, isJs: Bool)? {
    guard let npmCacheDir = findNpmCacheDir() else { return nil }
    let npxDir = (npmCacheDir as NSString).appendingPathComponent("_npx")

    guard let hashes = try? FileManager.default.contentsOfDirectory(atPath: npxDir) else { return nil }

    let packageName = packageSpec.components(separatedBy: "@").first(where: { !$0.isEmpty }).map { str -> String in
        packageSpec.hasPrefix("@") ? "@\(str)" : str
    } ?? packageSpec

    for hash in hashes {
        let nodeModulesPath = (npxDir as NSString)
            .appendingPathComponent(hash)
        let pkgJsonPath = ((nodeModulesPath as NSString)
            .appendingPathComponent("node_modules") as NSString)
            .appendingPathComponent(packageName)

        let packageJsonPath = (pkgJsonPath as NSString).appendingPathComponent("package.json")
        guard let data = FileManager.default.contents(atPath: packageJsonPath),
              let pkgJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            continue
        }

        // Find the binary path
        guard let binPath = findBinaryPath(packageDir: pkgJsonPath, pkgJson: pkgJson, binName: binName) else {
            continue
        }

        let isJs = isJavaScriptFile(binPath)
        return (binPath, isJs)
    }

    return nil
}

private func findNpmCacheDir() -> String? {
    if let envCache = ProcessInfo.processInfo.environment["NPM_CONFIG_CACHE"] {
        return envCache
    }
    let defaultPath = (NSHomeDirectory() as NSString).appendingPathComponent(".npm")
    if FileManager.default.fileExists(atPath: defaultPath) {
        return defaultPath
    }
    return nil
}

private func findBinaryPath(packageDir: String, pkgJson: [String: Any], binName: String?) -> String? {
    let binField = pkgJson["bin"]
    let candidates: [String]

    if let binDict = binField as? [String: String] {
        if let name = binName, let path = binDict[name] {
            candidates = [path]
        } else if let pkgName = pkgJson["name"] as? String {
            let shortName = pkgName.components(separatedBy: "/").last ?? pkgName
            if let path = binDict[shortName] {
                candidates = [path]
            } else if binDict.count == 1, let first = binDict.values.first {
                candidates = [first]
            } else {
                candidates = Array(binDict.values)
            }
        } else {
            candidates = Array(binDict.values)
        }
    } else if let binStr = binField as? String {
        candidates = [binStr]
    } else {
        return nil
    }

    for relPath in candidates {
        let fullPath = (packageDir as NSString).appendingPathComponent(relPath)
        if FileManager.default.fileExists(atPath: fullPath) {
            return fullPath
        }
    }

    // Also check .bin symlinks
    let nodeModulesDir = (packageDir as NSString).deletingLastPathComponent
    let binDir = (nodeModulesDir as NSString).appendingPathComponent(".bin")
    if let name = binName ?? (pkgJson["name"] as? String)?.components(separatedBy: "/").last {
        let symlinkPath = (binDir as NSString).appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: symlinkPath) {
            if let resolved = try? FileManager.default.destinationOfSymbolicLink(atPath: symlinkPath) {
                let absoluteResolved = resolved.hasPrefix("/") ? resolved : (binDir as NSString).appendingPathComponent(resolved)
                if FileManager.default.fileExists(atPath: absoluteResolved) {
                    return absoluteResolved
                }
            }
            return symlinkPath
        }
    }

    return nil
}

// MARK: - JS Detection

func isJavaScriptFile(_ path: String) -> Bool {
    let ext = (path as NSString).pathExtension.lowercased()
    if ext == "js" || ext == "mjs" || ext == "cjs" {
        return true
    }

    // Check shebang
    guard let handle = FileHandle(forReadingAtPath: path) else { return false }
    defer { handle.closeFile() }
    let headerData = handle.readData(ofLength: 256)
    guard let header = String(data: headerData, encoding: .utf8) else { return false }
    return header.hasPrefix("#!") && header.contains("node")
}

// MARK: - Force Populate

private func forcePopulate(packageSpec: String, binName: String?) async -> (binPath: String, isJs: Bool)? {
    // Run: npm exec --yes --package <spec> -- node -e 1
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["npm", "exec", "--yes", "--package", packageSpec, "--", "node", "-e", "1"]

    let devNull = Pipe()
    process.standardOutput = devNull
    process.standardError = devNull

    do {
        try process.run()
    } catch {
        return nil
    }

    // Wait with timeout (30s)
    let completed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
        let timer = DispatchSource.makeTimerSource()
        timer.schedule(deadline: .now() + 30)
        timer.setEventHandler {
            if process.isRunning { process.terminate() }
            timer.cancel()
            continuation.resume(returning: false)
        }
        timer.resume()

        process.terminationHandler = { _ in
            timer.cancel()
            continuation.resume(returning: true)
        }
    }

    guard completed, process.terminationStatus == 0 else { return nil }

    // Now try resolving from cache again
    return resolveFromNpmCache(packageSpec: packageSpec, binName: binName)
}
