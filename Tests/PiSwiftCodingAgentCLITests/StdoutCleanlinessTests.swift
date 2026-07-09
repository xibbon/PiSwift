import Darwin
import Foundation
import Testing
import PiSwiftCodingAgent

private func makeStdoutCleanlinessTempDir() throws -> String {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pi-stdout-cleanliness-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.path
}

private func resolveStdoutCleanlinessCliPath() -> String {
    let fileManager = FileManager.default
    if let override = ProcessInfo.processInfo.environment["PI_CODING_AGENT_CLI_PATH"],
       fileManager.isExecutableFile(atPath: override) {
        return override
    }
    let testExecutable = ProcessInfo.processInfo.arguments[0]
    let base = URL(fileURLWithPath: testExecutable).deletingLastPathComponent()
    let candidates = [
        base.appendingPathComponent("pi-coding-agent").path,
        URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent(".build")
            .appendingPathComponent("out")
            .appendingPathComponent("Products")
            .appendingPathComponent("Debug")
            .appendingPathComponent("pi-coding-agent")
            .path,
        URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent(".build")
            .appendingPathComponent("arm64-apple-macosx")
            .appendingPathComponent("debug")
            .appendingPathComponent("pi-coding-agent")
            .path,
    ]
    return candidates.first { fileManager.isExecutableFile(atPath: $0) } ?? candidates[0]
}

private func readPipe(_ pipe: Pipe) async -> String {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
        }
    }
}

private func writeTestAuth(agentDir: String, provider: String = "anthropic") throws {
    let authPath = URL(fileURLWithPath: agentDir).appendingPathComponent("auth.json")
    let json = #"{"\#(provider)":{"type":"api_key","key":"test-key"}}"#
    try json.write(to: authPath, atomically: true, encoding: .utf8)
}

private func stdoutCleanlinessEnvironment(agentDir: String) -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    env[ENV_AGENT_DIR] = agentDir
    if env["PI_EXTENSION_SDK_PATH"] == nil,
       let sdkPaths = ExtensionCompiler.resolveSDKPaths() {
        env["PI_EXTENSION_SDK_PATH"] = sdkPaths.libPath
    }
    return env
}

private func writeNoisyProjectExtension(cwd: String) throws -> String {
    let extensionDir = URL(fileURLWithPath: cwd)
        .appendingPathComponent(CONFIG_DIR_NAME)
        .appendingPathComponent("extensions")
    try FileManager.default.createDirectory(at: extensionDir, withIntermediateDirectories: true)
    let extensionPath = extensionDir.appendingPathComponent("noisy-extension.swift")
    let source = """
    import PiExtensionSDK
    import Foundation

    @_cdecl("piExtensionMain")
    public func piExtensionMain(_ raw: UnsafeMutableRawPointer) {
        print("extension stdout noise")
        withExtensionAPI(raw) { pi in
            pi.on("session_start") { (event: SessionStartEvent, ctx: HookContext) in
                return nil
            }
        }
    }
    """
    try source.write(to: extensionPath, atomically: true, encoding: .utf8)
    return extensionPath.path
}

private func runCLI(
    _ args: [String],
    cwd: String,
    agentDir: String
) async throws -> (status: Int32, stdout: String, stderr: String) {
    let process = Process()
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.executableURL = URL(fileURLWithPath: resolveStdoutCleanlinessCliPath())
    process.arguments = args
    process.currentDirectoryURL = URL(fileURLWithPath: cwd)
    process.environment = stdoutCleanlinessEnvironment(agentDir: agentDir)
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    try process.run()
    stdinPipe.fileHandleForWriting.closeFile()
    process.waitUntilExit()
    stdoutPipe.fileHandleForWriting.closeFile()
    stderrPipe.fileHandleForWriting.closeFile()

    async let stdout = readPipe(stdoutPipe)
    async let stderr = readPipe(stderrPipe)
    return (process.terminationStatus, await stdout, await stderr)
}

@Test func printModeRedirectsStartupStdoutNoiseToStderr() async throws {
    let tempDir = try makeStdoutCleanlinessTempDir()
    defer { try? FileManager.default.removeItem(atPath: tempDir) }
    let cwd = URL(fileURLWithPath: tempDir).appendingPathComponent("project").path
    let agentDir = URL(fileURLWithPath: tempDir).appendingPathComponent("agent").path
    let noisyPromptPath = URL(fileURLWithPath: tempDir).appendingPathComponent("prompt-dir").path
    try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: agentDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: noisyPromptPath, withIntermediateDirectories: true)
    try writeTestAuth(agentDir: agentDir)

    let result = try await runCLI([
        "--print",
        "--provider", "anthropic",
        "--model", "claude-sonnet-4-5",
        "--system-prompt", noisyPromptPath,
        "--no-session",
        "--no-extensions",
        "--no-skills",
        "--no-prompt-templates",
        "--nc",
    ], cwd: cwd, agentDir: agentDir)

    #expect(result.status == 0)
    #expect(result.stdout == "")
    #expect(result.stderr.contains("Warning: Could not read system prompt file"))
}

@Test func rpcModeRedirectsStartupStdoutNoiseToStderr() async throws {
    let tempDir = try makeStdoutCleanlinessTempDir()
    defer { try? FileManager.default.removeItem(atPath: tempDir) }
    let cwd = URL(fileURLWithPath: tempDir).appendingPathComponent("project").path
    let agentDir = URL(fileURLWithPath: tempDir).appendingPathComponent("agent").path
    let noisyPromptPath = URL(fileURLWithPath: tempDir).appendingPathComponent("prompt-dir").path
    try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: agentDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: noisyPromptPath, withIntermediateDirectories: true)
    try writeTestAuth(agentDir: agentDir)

    let process = Process()
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.executableURL = URL(fileURLWithPath: resolveStdoutCleanlinessCliPath())
    process.arguments = [
        "--mode", "rpc",
        "--provider", "anthropic",
        "--model", "claude-sonnet-4-5",
        "--system-prompt", noisyPromptPath,
        "--no-session",
        "--no-extensions",
        "--no-skills",
        "--no-prompt-templates",
        "--nc",
    ]
    process.currentDirectoryURL = URL(fileURLWithPath: cwd)
    process.environment = stdoutCleanlinessEnvironment(agentDir: agentDir)
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    try process.run()

    let payload = #"{"type":"get_state","id":"state_1"}"# + "\n"
    try stdinPipe.fileHandleForWriting.write(contentsOf: Data(payload.utf8))
    let line = try readFirstLine(stdoutPipe, timeout: 5)
    stdinPipe.fileHandleForWriting.closeFile()
    process.waitUntilExit()
    stdoutPipe.fileHandleForWriting.closeFile()
    stderrPipe.fileHandleForWriting.closeFile()

    let stderr = await readPipe(stderrPipe)
    let data = try #require(line.data(using: .utf8))
    let object = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]

    #expect(process.terminationStatus == 0)
    #expect(object?["type"] as? String == "response")
    #expect(object?["id"] as? String == "state_1")
    #expect(object?["success"] as? Bool == true)
    #expect(stderr.contains("Warning: Could not read system prompt file"))
}

@Test func printModeRedirectsExtensionStdoutNoiseToStderr() async throws {
    let tempDir = try makeStdoutCleanlinessTempDir()
    defer { try? FileManager.default.removeItem(atPath: tempDir) }
    let cwd = URL(fileURLWithPath: tempDir).appendingPathComponent("project").path
    let agentDir = URL(fileURLWithPath: tempDir).appendingPathComponent("agent").path
    try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: agentDir, withIntermediateDirectories: true)
    try writeTestAuth(agentDir: agentDir)
    _ = try writeNoisyProjectExtension(cwd: cwd)

    let result = try await runCLI([
        "--print",
        "--approve",
        "--provider", "anthropic",
        "--model", "claude-sonnet-4-5",
        "--no-session",
        "--no-skills",
        "--no-prompt-templates",
        "--nc",
    ], cwd: cwd, agentDir: agentDir)

    #expect(result.status == 0)
    #expect(result.stdout == "")
    #expect(result.stderr.contains("extension stdout noise"))
}

@Test func rpcModeRedirectsExtensionStdoutNoiseToStderr() async throws {
    let tempDir = try makeStdoutCleanlinessTempDir()
    defer { try? FileManager.default.removeItem(atPath: tempDir) }
    let cwd = URL(fileURLWithPath: tempDir).appendingPathComponent("project").path
    let agentDir = URL(fileURLWithPath: tempDir).appendingPathComponent("agent").path
    try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: agentDir, withIntermediateDirectories: true)
    try writeTestAuth(agentDir: agentDir)
    _ = try writeNoisyProjectExtension(cwd: cwd)

    let process = Process()
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.executableURL = URL(fileURLWithPath: resolveStdoutCleanlinessCliPath())
    process.arguments = [
        "--mode", "rpc",
        "--approve",
        "--provider", "anthropic",
        "--model", "claude-sonnet-4-5",
        "--no-session",
        "--no-skills",
        "--no-prompt-templates",
        "--nc",
    ]
    process.currentDirectoryURL = URL(fileURLWithPath: cwd)
    process.environment = stdoutCleanlinessEnvironment(agentDir: agentDir)
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    try process.run()

    let payload = #"{"type":"get_state","id":"state_1"}"# + "\n"
    try stdinPipe.fileHandleForWriting.write(contentsOf: Data(payload.utf8))
    let line = try readFirstLine(stdoutPipe, timeout: 10)
    stdinPipe.fileHandleForWriting.closeFile()
    process.waitUntilExit()
    stdoutPipe.fileHandleForWriting.closeFile()
    stderrPipe.fileHandleForWriting.closeFile()

    let stderr = await readPipe(stderrPipe)
    let data = try #require(line.data(using: .utf8))
    let object = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]

    #expect(process.terminationStatus == 0)
    #expect(object?["type"] as? String == "response")
    #expect(object?["id"] as? String == "state_1")
    #expect(object?["success"] as? Bool == true)
    #expect(stderr.contains("extension stdout noise"))
}

@Test func rpcModeSigtermExitsWithPiMonoStatus() throws {
    try assertRpcSignalExit(signal: SIGTERM, expectedStatus: 143)
}

@Test func rpcModeSighupExitsWithPiMonoStatus() throws {
    try assertRpcSignalExit(signal: SIGHUP, expectedStatus: 129)
}

@Test func rpcModeSigtermKillsRunningBashChild() throws {
    let tempDir = try makeStdoutCleanlinessTempDir()
    defer { try? FileManager.default.removeItem(atPath: tempDir) }
    let cwd = URL(fileURLWithPath: tempDir).appendingPathComponent("project").path
    let agentDir = URL(fileURLWithPath: tempDir).appendingPathComponent("agent").path
    let sleepPidPath = URL(fileURLWithPath: tempDir).appendingPathComponent("sleep.pid").path
    try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: agentDir, withIntermediateDirectories: true)
    try writeTestAuth(agentDir: agentDir)

    let process = Process()
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.executableURL = URL(fileURLWithPath: resolveStdoutCleanlinessCliPath())
    process.arguments = [
        "--mode", "rpc",
        "--provider", "anthropic",
        "--model", "claude-sonnet-4-5",
        "--no-session",
        "--no-extensions",
        "--no-skills",
        "--no-prompt-templates",
        "--nc",
    ]
    process.currentDirectoryURL = URL(fileURLWithPath: cwd)
    process.environment = stdoutCleanlinessEnvironment(agentDir: agentDir)
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    try process.run()

    let command = "sleep 30 & echo $! > \(shellQuote(sleepPidPath)); wait $!"
    let payload = try JSONSerialization.data(withJSONObject: [
        "type": "bash",
        "id": "bash_1",
        "command": command,
        "excludeFromContext": true,
    ], options: [])
    try stdinPipe.fileHandleForWriting.write(contentsOf: payload + Data([0x0A]))

    let sleepPidText = try waitForFileText(sleepPidPath, timeout: 5)
    let sleepPid = try #require(pid_t(sleepPidText.trimmingCharacters(in: .whitespacesAndNewlines)))
    defer {
        if isPidAlive(sleepPid) {
            _ = kill(sleepPid, SIGKILL)
        }
    }

    kill(process.processIdentifier, SIGTERM)
    try waitForProcessExit(process, timeout: 5)
    stdinPipe.fileHandleForWriting.closeFile()
    stdoutPipe.fileHandleForWriting.closeFile()
    stderrPipe.fileHandleForWriting.closeFile()

    #expect(process.terminationStatus == 143)
    #expect(waitForPidExit(sleepPid, timeout: 5))
}

private func assertRpcSignalExit(signal: Int32, expectedStatus: Int32) throws {
    let tempDir = try makeStdoutCleanlinessTempDir()
    defer { try? FileManager.default.removeItem(atPath: tempDir) }
    let cwd = URL(fileURLWithPath: tempDir).appendingPathComponent("project").path
    let agentDir = URL(fileURLWithPath: tempDir).appendingPathComponent("agent").path
    try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: agentDir, withIntermediateDirectories: true)
    try writeTestAuth(agentDir: agentDir)

    let process = Process()
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.executableURL = URL(fileURLWithPath: resolveStdoutCleanlinessCliPath())
    process.arguments = [
        "--mode", "rpc",
        "--provider", "anthropic",
        "--model", "claude-sonnet-4-5",
        "--no-session",
        "--no-extensions",
        "--no-skills",
        "--no-prompt-templates",
        "--nc",
    ]
    process.currentDirectoryURL = URL(fileURLWithPath: cwd)
    process.environment = stdoutCleanlinessEnvironment(agentDir: agentDir)
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    try process.run()
    let payload = #"{"type":"get_state","id":"state_1"}"# + "\n"
    try stdinPipe.fileHandleForWriting.write(contentsOf: Data(payload.utf8))
    let line = try readFirstLine(stdoutPipe, timeout: 5)
    #expect(line.contains(#""id":"state_1""#))

    kill(process.processIdentifier, signal)
    try waitForProcessExit(process, timeout: 5)
    stdinPipe.fileHandleForWriting.closeFile()
    stdoutPipe.fileHandleForWriting.closeFile()
    stderrPipe.fileHandleForWriting.closeFile()

    #expect(process.terminationStatus == expectedStatus)
}

private func readFirstLine(_ pipe: Pipe, timeout: TimeInterval) throws -> String {
    let fd = pipe.fileHandleForReading.fileDescriptor
    let semaphore = DispatchSemaphore(value: 0)
    let state = ProtectedLineState()

    DispatchQueue.global().async {
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while true {
            let count = Darwin.read(fd, &byte, 1)
            if count <= 0 { break }
            if byte == 0x0A { break }
            bytes.append(byte)
        }
        state.set(String(decoding: bytes, as: UTF8.self))
        semaphore.signal()
    }

    if semaphore.wait(timeout: .now() + timeout) == .timedOut {
        throw RpcTestError(message: "Timed out waiting for RPC stdout line")
    }
    return state.get()
}

private func waitForProcessExit(_ process: Process, timeout: TimeInterval) throws {
    let semaphore = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        process.waitUntilExit()
        semaphore.signal()
    }
    if semaphore.wait(timeout: .now() + timeout) == .timedOut {
        process.terminate()
        throw RpcTestError(message: "Timed out waiting for process exit")
    }
}

private func waitForFileText(_ path: String, timeout: TimeInterval) throws -> String {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let text = try? String(contentsOfFile: path, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        usleep(50_000)
    }
    throw RpcTestError(message: "Timed out waiting for file \(path)")
}

private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private func isPidAlive(_ pid: pid_t) -> Bool {
    if kill(pid, 0) == 0 {
        return true
    }
    return errno == EPERM
}

private func waitForPidExit(_ pid: pid_t, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if !isPidAlive(pid) {
            return true
        }
        usleep(50_000)
    }
    return !isPidAlive(pid)
}

private final class ProtectedLineState: @unchecked Sendable {
    private let lock = NSLock()
    private var line = ""

    func set(_ value: String) {
        lock.lock()
        line = value
        lock.unlock()
    }

    func get() -> String {
        lock.lock()
        defer { lock.unlock() }
        return line
    }
}
