import Foundation
import PiSwiftAI

public struct ToolStatus: Sendable {
    public enum Kind: String, Sendable { case info, warning }
    public var type: Kind
    public var message: String

    public init(type: Kind, message: String) {
        self.type = type
        self.message = message
    }
}

/// The Boolean controls whether HTTP redirects are followed.
public typealias ToolManagerTransport = @Sendable (URLRequest, Bool) async throws -> ManagementHTTPResponse
public typealias ToolManagerCommandRunner = @Sendable (String, [String], String) async throws -> ExecResult

private struct ManagedTool: Sendable {
    let name: String
    let repo: String
    let binaryName: String
    let systemNames: [String]
    let tagPrefix: String

    static func named(_ name: String) -> Self? {
        switch name {
        case "fd": return Self(name: "fd", repo: "sharkdp/fd", binaryName: "fd", systemNames: ["fd", "fdfind"], tagPrefix: "v")
        case "rg": return Self(name: "ripgrep", repo: "BurntSushi/ripgrep", binaryName: "rg", systemNames: ["rg"], tagPrefix: "")
        default: return nil
        }
    }
}

private struct ToolManagerError: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private final class ToolRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    let followRedirects: Bool
    init(_ followRedirects: Bool) { self.followRedirects = followRedirects }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(followRedirects ? request : nil)
    }
}

private func defaultToolTransport(_ request: URLRequest, _ followRedirects: Bool) async throws -> ManagementHTTPResponse {
    let data: Data
    let response: URLResponse
    if followRedirects {
        (data, response) = try await URLSession.shared.data(for: request, delegate: ToolRedirectPolicy(true))
    } else {
        let (bytes, headers) = try await URLSession.shared.bytes(for: request, delegate: ToolRedirectPolicy(false))
        // Release lookup needs only the redirect headers. Do not wait for its body.
        bytes.task.cancel()
        data = Data()
        response = headers
    }
    guard let response = response as? HTTPURLResponse else { throw ToolManagerError("Invalid HTTP response") }
    let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, entry in
        result[String(describing: entry.key)] = String(describing: entry.value)
    }
    return ManagementHTTPResponse(statusCode: response.statusCode, headers: headers, body: data)
}

private struct ToolTransportClient: ProviderHTTPClient {
    let transport: ToolManagerTransport
    let followRedirects: Bool

    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        let response = try await transport(request, followRedirects)
        return ProviderHTTPResponse(statusCode: response.statusCode, headers: response.headers, body: response.body)
    }
}

/// Return the release asset for a supported platform. Linux assets use musl on both architectures.
public func toolDownloadAssetName(_ tool: String, version: String, platform: String, architecture: String) -> String? {
    guard let config = ManagedTool.named(tool) else { return nil }
    let architecture = architecture == "arm64" ? "aarch64" : "x86_64"
    let suffix: String
    switch platform {
    case "darwin": suffix = "apple-darwin.tar.gz"
    case "linux": suffix = "unknown-linux-musl.tar.gz"
    case "win32": suffix = "pc-windows-msvc.zip"
    default: return nil
    }
    return "\(config.name)-\(config.tagPrefix)\(version)-\(architecture)-\(suffix)"
}

/// Library-only tool installation. Progress is sent to the callback, never to stdout.
/// HTTP and extraction operations can be supplied by an embedder or an offline test.
public struct ToolManager: Sendable {
    public let toolsDirectory: String
    public let platform: String
    public let architecture: String
    private let environment: [String: String]
    private let transport: ToolManagerTransport
    private let commandRunner: ToolManagerCommandRunner?

    public init(
        toolsDirectory: String? = nil,
        platform: String? = nil,
        architecture: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        transport: ToolManagerTransport? = nil,
        commandRunner: ToolManagerCommandRunner? = nil
    ) {
        self.toolsDirectory = toolsDirectory ?? URL(fileURLWithPath: getAgentDir()).appendingPathComponent("bin").path
        self.platform = platform ?? Self.currentPlatform
        self.architecture = architecture ?? Self.currentArchitecture
        self.environment = environment
        self.transport = transport ?? defaultToolTransport
        self.commandRunner = commandRunner
    }

    private static var currentPlatform: String {
        #if os(macOS)
        "darwin"
        #elseif os(iOS)
        "ios"
        #elseif os(Linux)
        "linux"
        #elseif os(Windows)
        "win32"
        #else
        "unsupported"
        #endif
    }

    private static var currentArchitecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x64"
        #endif
    }

    public func getToolPath(_ name: String) -> String? {
        guard platform != "ios" else { return nil }
        let config = ManagedTool.named(name)
        if let config {
            let path = binaryPath(config)
            var directory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &directory), !directory.boolValue { return path }
        }
        // Keep support for installed commands other than the two downloadable tools.
        guard !name.contains("/"), !name.contains("\\") else { return nil }
        let pathKey = environment.keys.first { $0.lowercased() == "path" }
        let path = pathKey.flatMap { environment[$0] } ?? ""
        guard !path.isEmpty else { return nil }
        let separator: Character = platform == "win32" ? ";" : ":"
        for binary in config?.systemNames ?? [name] {
            for directory in path.split(separator: separator, omittingEmptySubsequences: false) {
                let file = URL(fileURLWithPath: String(directory)).appendingPathComponent(binary + (platform == "win32" ? ".exe" : "")).path
                if FileManager.default.isExecutableFile(atPath: file) { return file }
            }
        }
        return nil
    }

    public func ensureTool(_ name: String, onStatus: (@Sendable (ToolStatus) -> Void)? = nil) async -> String? {
        if let path = getToolPath(name) { return path }
        guard let config = ManagedTool.named(name) else {
            onStatus?(ToolStatus(type: .warning, message: "\(name) not found. Automatic downloads are available only for fd and rg."))
            return nil
        }
        if ["1", "true", "yes"].contains((environment["PI_OFFLINE"] ?? "").lowercased()) {
            onStatus?(ToolStatus(type: .warning, message: "\(config.name) not found. Offline mode enabled, skipping download."))
            return nil
        }
        if platform == "android" {
            onStatus?(ToolStatus(type: .warning, message: "\(config.name) not found. Install with: pkg install \(config.name)"))
            return nil
        }
        if platform == "ios" || (Self.currentPlatform != "darwin" && commandRunner == nil) {
            onStatus?(ToolStatus(type: .warning, message: "\(config.name) not found. Tool installation is unavailable on this platform."))
            return nil
        }
        onStatus?(ToolStatus(type: .info, message: "\(config.name) not found. Downloading..."))
        do {
            let path = try await downloadTool(config)
            onStatus?(ToolStatus(type: .info, message: "\(config.name) installed to \(path)"))
            return path
        } catch {
            onStatus?(ToolStatus(type: .warning, message: "Failed to download \(config.name): \(toolDownloadErrorMessage(error))"))
            return nil
        }
    }

    public func getLatestVersion(_ repo: String) async throws -> String {
        guard let url = URL(string: "https://github.com/\(repo)/releases/latest") else {
            throw ToolManagerError("Failed to resolve latest \(repo) release: invalid repository URL")
        }
        let response = try await fetch(url, followRedirects: false, timeout: 10)
        let location = (300..<400).contains(response.statusCode)
            ? response.headers.first { $0.key.lowercased() == "location" }?.value : nil
        guard let location, !location.isEmpty else {
            throw ToolManagerError("Failed to resolve latest \(repo) release: HTTP \(response.statusCode) without redirect")
        }
        guard location.contains("/releases/tag/"),
              let target = URL(string: location, relativeTo: URL(string: "https://github.com")!)?.absoluteURL,
              let encodedTag = target.path(percentEncoded: true).split(separator: "/", omittingEmptySubsequences: false).last,
              let tag = String(encodedTag).removingPercentEncoding, !tag.isEmpty else {
            throw ToolManagerError("Failed to resolve latest \(repo) release: unexpected redirect to \(location)")
        }
        return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    private func fetch(_ url: URL, followRedirects: Bool, timeout: Double) async throws -> ManagementHTTPResponse {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("\(APP_NAME)-coding-agent", forHTTPHeaderField: "User-Agent")
        return try await fetchWithRetry(request, client: ToolTransportClient(transport: transport, followRedirects: followRedirects), options: FetchRetryOptions(timeoutMs: timeout * 1_000))
    }

    private func binaryPath(_ config: ManagedTool) -> String {
        URL(fileURLWithPath: toolsDirectory).appendingPathComponent(config.binaryName + (platform == "win32" ? ".exe" : "")).path
    }

    private func downloadTool(_ config: ManagedTool) async throws -> String {
        let version = config.binaryName == "fd" && platform == "darwin" && architecture == "x64"
            ? "10.3.0" : try await getLatestVersion(config.repo)
        guard let asset = toolDownloadAssetName(config.binaryName, version: version, platform: platform, architecture: architecture) else {
            throw ToolManagerError("Unsupported platform: \(platform)/\(architecture)")
        }
        let manager = FileManager.default
        let work = URL(fileURLWithPath: toolsDirectory).appendingPathComponent("extract_tmp_\(config.binaryName)_\(UUID().uuidString)")
        let extract = work.appendingPathComponent("contents")
        try manager.createDirectory(at: extract, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: work) }
        let archive = work.appendingPathComponent(asset)
        let url = URL(string: "https://github.com/\(config.repo)/releases/download/\(config.tagPrefix)\(version)/\(asset)")!
        let response = try await fetch(url, followRedirects: true, timeout: 120)
        guard (200..<300).contains(response.statusCode) else {
            throw ToolManagerError("Download failed with HTTP \(response.statusCode): \(url.absoluteString)")
        }
        try response.body.write(to: archive)
        try await extractArchive(archive.path, to: extract.path, asset: asset)
        let binaryName = config.binaryName + (platform == "win32" ? ".exe" : "")
        guard let extracted = findBinary(in: extract, named: binaryName) else {
            throw ToolManagerError("Binary not found in archive: expected \(binaryName) under \(extract.path)")
        }
        if platform != "win32" { try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: extracted.path) }
        let destination = binaryPath(config)
        return try await FileMutationQueue.shared.withFileLock(destination) {
            let manager = FileManager.default
            // Concurrent installs have separate work directories. The first installed file wins.
            if !manager.fileExists(atPath: destination) { try manager.moveItem(atPath: extracted.path, toPath: destination) }
            return destination
        }
    }

    private func run(_ command: String, _ arguments: [String], cwd: String) async throws -> ExecResult {
        if let commandRunner { return try await commandRunner(command, arguments, cwd) }
        #if os(macOS)
        return try await execCommand(command, arguments, cwd, ExecOptions(timeout: 120, maxOutputBytes: 1_048_576))
        #else
        throw ToolManagerError("Archive extraction is unavailable on this platform")
        #endif
    }

    private func extractArchive(_ archive: String, to directory: String, asset: String) async throws {
        let commands: [(String, [String])]
        if asset.hasSuffix(".tar.gz") {
            commands = [("tar", ["xzf", archive, "-C", directory])]
        } else if asset.hasSuffix(".zip"), platform == "win32" {
            let root = environment["SystemRoot"] ?? environment["WINDIR"]
            let systemTar = root.map { URL(fileURLWithPath: $0).appendingPathComponent("System32/tar.exe").path }
            let tar = systemTar.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } ?? "tar.exe"
            commands = [
                (tar, ["xf", archive, "-C", directory]),
                ("powershell.exe", ["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", "& { param($archive, $destination) $ErrorActionPreference = 'Stop'; Expand-Archive -LiteralPath $archive -DestinationPath $destination -Force }", archive, directory]),
            ]
        } else if asset.hasSuffix(".zip") {
            commands = [("unzip", ["-q", archive, "-d", directory]), ("tar", ["xf", archive, "-C", directory])]
        } else {
            throw ToolManagerError("Unsupported archive format: \(asset)")
        }
        var failures: [String] = []
        for (command, arguments) in commands {
            do {
                let result = try await run(command, arguments, cwd: directory)
                if result.code == 0 && !result.killed { return }
                let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                failures.append("\(command): \(!stderr.isEmpty ? stderr : (!stdout.isEmpty ? stdout : "exit status \(result.code)"))")
            } catch {
                failures.append("\(command): \(error.localizedDescription)")
            }
        }
        throw ToolManagerError("Failed to extract \(asset): \(failures.joined(separator: "; "))")
    }
}

private func findBinary(in root: URL, named name: String) -> URL? {
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
    guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys)) else { return nil }
    while let file = entries.nextObject() as? URL {
        guard let values = try? file.resourceValues(forKeys: keys) else { continue }
        if values.isSymbolicLink == true { entries.skipDescendants(); continue }
        if values.isRegularFile == true && file.lastPathComponent == name { return file }
    }
    return nil
}

/// An error can expose a nested transport or extraction failure for status text.
public protocol ErrorWithCause: Error {
    var cause: (any Error)? { get }
}

func toolDownloadErrorMessage(_ error: any Error) -> String {
    var current: (any Error)? = error
    var messages: [String] = []
    for _ in 0..<5 {
        guard let error = current else { break }
        let message = error.localizedDescription
        if !messages.contains(message) { messages.append(message) }
        if let causal = error as? any ErrorWithCause {
            current = causal.cause
        } else if let urlError = error as? URLError {
            current = urlError.userInfo[NSUnderlyingErrorKey] as? any Error
        } else {
            current = nil
        }
    }
    return messages.joined(separator: ": ")
}

public func getToolPath(_ name: String) -> String? { ToolManager().getToolPath(name) }
public func getLatestVersion(_ repo: String, transport: ToolManagerTransport? = nil) async throws -> String {
    try await ToolManager(transport: transport).getLatestVersion(repo)
}

public func ensureTool(_ name: String) async -> String? { await ToolManager().ensureTool(name) }
public func ensureTool(_ name: String, onStatus: (@Sendable (ToolStatus) -> Void)?) async -> String? {
    await ToolManager().ensureTool(name, onStatus: onStatus)
}

@available(*, deprecated, message: "Use ensureTool(_:onStatus:). Status messages are silent without a callback.")
public func ensureTool(_ name: String, silent: Bool) async -> String? {
    await ensureTool(name)
}
