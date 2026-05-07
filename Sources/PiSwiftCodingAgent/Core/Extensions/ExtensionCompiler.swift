import Foundation
import CryptoKit

/// Compiles `.swift` extension files and SPM package directories into loadable dylibs.
public struct ExtensionCompiler {

    /// Paths to the PiExtensionSDK module and library used during compilation.
    public struct SDKPaths: Sendable {
        /// Directory containing `PiExtensionSDK.swiftmodule`
        public let modulePath: String
        /// Directory containing `libPiExtensionSDK.dylib`
        public let libPath: String

        public init(modulePath: String, libPath: String) {
            self.modulePath = modulePath
            self.libPath = libPath
        }
    }

    // MARK: - Public API

    /// Compile a single `.swift` file to a dylib, using the cache when possible.
    /// - Returns: Path to the compiled `.dylib`.
    public static func compileSingleFile(
        sourcePath: String,
        cacheDir: String,
        sdkPaths: SDKPaths
    ) async throws -> String {
        let sourceData = try Data(contentsOf: URL(fileURLWithPath: sourcePath))
        let sourceHash = sha256(sourceData)

        // Include SDK dylib hash so cache invalidates when PiSwift itself changes.
        let sdkDylibPath = (sdkPaths.libPath as NSString).appendingPathComponent("libPiExtensionSDK.dylib")
        let sdkHash: String
        if let sdkData = try? Data(contentsOf: URL(fileURLWithPath: sdkDylibPath)) {
            sdkHash = sha256(sdkData)
        } else {
            sdkHash = "no-sdk"
        }

        let cacheKey = sha256(Data((sourceHash + sdkHash).utf8))
        let dylibName = "\(cacheKey).dylib"
        let dylibPath = (cacheDir as NSString).appendingPathComponent(dylibName)

        if FileManager.default.fileExists(atPath: dylibPath) {
            return dylibPath
        }

        try FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)

        let baseName = URL(fileURLWithPath: sourcePath).deletingPathExtension().lastPathComponent
        let moduleName = "PiExtension_\(sanitizeModuleName(baseName))"

        // Use -undefined dynamic_lookup instead of -lPiExtensionSDK so the
        // compiled extension doesn't carry a hard dependency on the SDK dylib.
        // Symbols are resolved at runtime from the host process, which already
        // has PiSwiftCodingAgent loaded.  This avoids duplicate ObjC class
        // registration when the extension is dlopen'd into a process that also
        // statically links the same modules.
        let args = [
            "swiftc",
            "-emit-library",
            "-o", dylibPath,
            "-module-name", moduleName,
            "-parse-as-library",
            "-swift-version", "6",
            "-I", sdkPaths.modulePath,
            "-Xlinker", "-undefined",
            "-Xlinker", "dynamic_lookup",
            sourcePath,
        ]

        let result = try await runProcess(args)
        guard result.exitCode == 0 else {
            // Clean up partial output
            try? FileManager.default.removeItem(atPath: dylibPath)
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ExtensionLoadError.compilationError(
                path: sourcePath,
                error: stderr.isEmpty ? "swiftc exited with code \(result.exitCode)" : stderr
            )
        }

        return dylibPath
    }

    /// Build an SPM package directory and return the path to the produced dylib.
    /// - Returns: Path to the built `.dylib`.
    public static func buildPackageDirectory(
        packageDir: String,
        cacheDir: String
    ) async throws -> String {
        let args = [
            "swift", "build",
            "--package-path", packageDir,
            "--configuration", "release",
        ]

        let result = try await runProcess(args)
        guard result.exitCode == 0 else {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ExtensionLoadError.packageLoadError(
                path: packageDir,
                error: stderr.isEmpty ? "swift build exited with code \(result.exitCode)" : stderr
            )
        }

        // Find the built dylib in .build/release/
        let releaseDir = (packageDir as NSString).appendingPathComponent(".build/release")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: releaseDir) else {
            throw ExtensionLoadError.packageLoadError(path: packageDir, error: "No build output found in .build/release/")
        }

        if let dylib = entries.first(where: { $0.hasSuffix(".dylib") }) {
            return (releaseDir as NSString).appendingPathComponent(dylib)
        }

        throw ExtensionLoadError.packageLoadError(path: packageDir, error: "No .dylib found in build output")
    }

    /// Resolve the SDK module and library paths for compiling extensions.
    public static func resolveSDKPaths() -> SDKPaths? {
        // 1. Explicit override via environment variable
        if let sdkDir = ProcessInfo.processInfo.environment["PI_EXTENSION_SDK_PATH"],
           !sdkDir.isEmpty,
           FileManager.default.fileExists(atPath: sdkDir) {
            // Honor a `Modules/` subdir if present so callers can ship one tree.
            let modulesSubdir = (sdkDir as NSString).appendingPathComponent("Modules")
            let moduleDir = FileManager.default.fileExists(atPath: (modulesSubdir as NSString).appendingPathComponent("PiExtensionSDK.swiftmodule"))
                ? modulesSubdir : sdkDir
            return SDKPaths(modulePath: moduleDir, libPath: sdkDir)
        }

        // 2. ~/.pi/agent/sdk/  (per-user install — no root required).
        //    Supports a flat layout (everything in sdk/) or sdk/Modules/ for the modules.
        let agentSDK = (getAgentDir() as NSString).appendingPathComponent("sdk")
        if let paths = sdkPathsAt(agentSDK) {
            return paths
        }

        // 3. Relative to the current executable (handles both `swift run` SPM build dir
        //    and "installed next to binary" layouts where the dylib + Modules/ live in
        //    the same directory as the executable).
        let execURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).deletingLastPathComponent()
        let execDir = execURL.path
        if let paths = sdkPathsAt(execDir) {
            return paths
        }

        // 4. FHS-style install: `<bin>/../lib/pi/` next to the binary, e.g.
        //    `~/.local/bin/pi-coding-agent` + `~/.local/lib/pi/{libPiExtensionSDK.dylib,Modules/...}`.
        let fhsLib = execURL.deletingLastPathComponent().appendingPathComponent("lib").appendingPathComponent("pi").path
        if let paths = sdkPathsAt(fhsLib) {
            return paths
        }

        // 5. SPM build artifacts (debug then release) — falls through when running tests
        //    or `swift run` from a sibling directory.
        for config in ["debug", "release"] {
            if let buildDir = findSPMBuildDir(config: config),
               let paths = sdkPathsAt(buildDir) {
                return paths
            }
        }

        return nil
    }

    /// Probe a candidate directory for the SDK artifacts. Returns nil when the dylib or
    /// the swiftmodule isn't present. Accepts either flat (everything in `dir`) or
    /// `dir/Modules/` layouts.
    /// Internal for testing: lets `compilerResolvesSDKPathsFromInstalledFHSLayout`
    /// verify layout detection without mutating `PI_EXTENSION_SDK_PATH` (which would
    /// race against parallel tests).
    static func sdkPathsAt(_ dir: String) -> SDKPaths? {
        let dylib = (dir as NSString).appendingPathComponent("libPiExtensionSDK.dylib")
        guard FileManager.default.fileExists(atPath: dylib) else { return nil }

        let modulesSubdir = (dir as NSString).appendingPathComponent("Modules")
        if FileManager.default.fileExists(atPath: (modulesSubdir as NSString).appendingPathComponent("PiExtensionSDK.swiftmodule")) {
            return SDKPaths(modulePath: modulesSubdir, libPath: dir)
        }
        if FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent("PiExtensionSDK.swiftmodule")) {
            return SDKPaths(modulePath: dir, libPath: dir)
        }
        return nil
    }

    // MARK: - Internal helpers

    static func sha256(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func sanitizeModuleName(_ name: String) -> String {
        var result = ""
        for ch in name {
            if ch.isLetter || ch.isNumber || ch == "_" {
                result.append(ch)
            } else {
                result.append("_")
            }
        }
        if result.isEmpty || result.first!.isNumber {
            result = "_" + result
        }
        return result
    }

    private struct ProcessResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private static func runProcess(_ args: [String]) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }

    private static func findSPMBuildDir(config: String) -> String? {
        // Walk up from the executable to find a .build directory
        var dir = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent(".build/\(config)").path
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }
}
