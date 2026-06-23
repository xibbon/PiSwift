import Foundation
import Testing
import PiSwiftAI
import PiSwiftCodingAgent

private func makeTempDir() throws -> String {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pi-rpc-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.path
}

private func removeTempDir(_ path: String) {
    try? FileManager.default.removeItem(atPath: path)
}

private func resolveCliPath() -> String {
    let testExecutable = ProcessInfo.processInfo.arguments[0]
    let base = URL(fileURLWithPath: testExecutable).deletingLastPathComponent()
    return base.appendingPathComponent("pi-coding-agent").path
}

private func makeClient(sessionDir: String) -> RpcTestClient {
    let cliPath = resolveCliPath()
    var env = ProcessInfo.processInfo.environment
    env[ENV_AGENT_DIR] = sessionDir
    return RpcTestClient(options: RpcTestClient.Options(
        cliPath: cliPath,
        cwd: FileManager.default.currentDirectoryPath,
        env: env,
        provider: "anthropic",
        model: "claude-sonnet-4-5",
        args: []
    ))
}

private func withRpcClient<T>(sessionDir: String, _ body: (RpcTestClient) async throws -> T) async throws -> T {
    let client = makeClient(sessionDir: sessionDir)
    try await client.start()
    do {
        let result = try await body(client)
        await client.stop()
        return result
    } catch {
        await client.stop()
        throw error
    }
}

private func waitForWrites() async {
    try? await Task.sleep(nanoseconds: 200_000_000)
}

private func loadSessionEntries(sessionDir: String) throws -> [[String: Any]] {
    let sessionsPath = URL(fileURLWithPath: sessionDir).appendingPathComponent("sessions").path
    let sessionDirs = try FileManager.default.contentsOfDirectory(atPath: sessionsPath)
        .filter { !$0.hasPrefix(".") }
    guard let sessionDirName = sessionDirs.first else {
        throw RpcTestError(message: "No session directories found")
    }
    let sessionPath = URL(fileURLWithPath: sessionsPath).appendingPathComponent(sessionDirName).path
    let sessionFiles = try FileManager.default.contentsOfDirectory(atPath: sessionPath).filter { $0.hasSuffix(".jsonl") }
    guard let sessionFileName = sessionFiles.first else {
        throw RpcTestError(message: "No session file found")
    }
    let sessionFile = URL(fileURLWithPath: sessionPath).appendingPathComponent(sessionFileName).path
    let content = try String(contentsOfFile: sessionFile, encoding: .utf8)
    return content
        .split(separator: "\n")
        .compactMap { line in
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data, options: []),
                  let dict = json as? [String: Any] else {
                return nil
            }
            return dict
        }
}

private func assistantText(from events: [[String: Any]]) -> String? {
    for event in events {
        guard event["type"] as? String == "message_end",
              let message = event["message"] as? [String: Any],
              message["role"] as? String == "assistant",
              let content = message["content"] as? [[String: Any]] else {
            continue
        }
        for block in content {
            if block["type"] as? String == "text", let text = block["text"] as? String {
                return text
            }
        }
    }
    return nil
}

private func value<T>(_ dict: [String: AnyCodable], _ key: String, as type: T.Type = T.self) -> T? {
    dict[key]?.value as? T
}

@Test func rpcGetState() async throws {
    guard API_KEY != nil else { return }

    let sessionDir = try makeTempDir()
    defer { removeTempDir(sessionDir) }

    try await withRpcClient(sessionDir: sessionDir) { client in
        let state = try await client.getState().value
        let model = value(state, "model", as: [String: Any].self)
        #expect(model != nil)
        #expect(model?["provider"] as? String == "anthropic")
        #expect(model?["id"] as? String == "claude-sonnet-4-5")
        #expect(value(state, "isStreaming", as: Bool.self) == false)
        #expect(value(state, "messageCount", as: Int.self) == 0)
    }
}

@Test func rpcSavesMessagesToSessionFile() async throws {
    guard API_KEY != nil else { return }

    let sessionDir = try makeTempDir()
    defer { removeTempDir(sessionDir) }

    try await withRpcClient(sessionDir: sessionDir) { client in
        let events = try await client.promptAndWait("Reply with just the word 'hello'").value
        let messageEnds = events.filter { value($0, "type", as: String.self) == "message_end" }
        #expect(messageEnds.count >= 2)

        await waitForWrites()
        let entries = try loadSessionEntries(sessionDir: sessionDir)
        #expect(entries.first?["type"] as? String == "session")

        let messages = entries.filter { ($0["type"] as? String) == "message" }
        #expect(messages.count >= 2)
        let roles = messages.compactMap { ($0["message"] as? [String: Any])?["role"] as? String }
        #expect(roles.contains("user"))
        #expect(roles.contains("assistant"))
    }
}

@Test func rpcManualCompaction() async throws {
    guard API_KEY != nil else { return }

    let sessionDir = try makeTempDir()
    defer { removeTempDir(sessionDir) }

    try await withRpcClient(sessionDir: sessionDir) { client in
        _ = try await client.promptAndWait("Say hello")
        let result = try await client.compact().value
        #expect(value(result, "summary", as: String.self)?.isEmpty == false)
        #expect((value(result, "tokensBefore", as: Int.self) ?? 0) > 0)

        await waitForWrites()
        let entries = try loadSessionEntries(sessionDir: sessionDir)
        let compactions = entries.filter { ($0["type"] as? String) == "compaction" }
        #expect(compactions.count == 1)
        #expect((compactions.first?["summary"] as? String)?.isEmpty == false)
    }
}

@Test func rpcExecuteBash() async throws {
    guard API_KEY != nil else { return }

    let sessionDir = try makeTempDir()
    defer { removeTempDir(sessionDir) }

    try await withRpcClient(sessionDir: sessionDir) { client in
        let result = try await client.bash("echo hello").value
        #expect(value(result, "output", as: String.self)?.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
        #expect(value(result, "exitCode", as: Int.self) == 0)
        #expect(value(result, "cancelled", as: Bool.self) == false)
    }
}

@Test func rpcBashOutputAddedToContext() async throws {
    guard API_KEY != nil else { return }

    let sessionDir = try makeTempDir()
    defer { removeTempDir(sessionDir) }

    try await withRpcClient(sessionDir: sessionDir) { client in
        _ = try await client.promptAndWait("Say hi")
        let uniqueValue = "test-\(Int(Date().timeIntervalSince1970 * 1000))"
        _ = try await client.bash("echo \(uniqueValue)")

        await waitForWrites()
        let entries = try loadSessionEntries(sessionDir: sessionDir)
        let bashEntries = entries.filter {
            guard ($0["type"] as? String) == "message" else { return false }
            let role = ($0["message"] as? [String: Any])?["role"] as? String
            return role == "bashExecution"
        }
        #expect(bashEntries.count == 1)
        let output = (bashEntries.first?["message"] as? [String: Any])?["output"] as? String
        #expect(output?.contains(uniqueValue) == true)
    }
}

@Test func rpcBashOutputCanBeExcludedFromContext() async throws {
    guard API_KEY != nil else { return }

    let sessionDir = try makeTempDir()
    defer { removeTempDir(sessionDir) }

    try await withRpcClient(sessionDir: sessionDir) { client in
        _ = try await client.promptAndWait("Say hi")
        let uniqueValue = "excluded-\(Int(Date().timeIntervalSince1970 * 1000))"
        let result = try await client.bash("echo \(uniqueValue)", excludeFromContext: true).value
        #expect(value(result, "output", as: String.self)?.contains(uniqueValue) == true)

        await waitForWrites()
        let entries = try loadSessionEntries(sessionDir: sessionDir)
        let bashEntries = entries.filter {
            guard ($0["type"] as? String) == "message" else { return false }
            let role = ($0["message"] as? [String: Any])?["role"] as? String
            return role == "bashExecution"
        }
        #expect(bashEntries.isEmpty)
    }
}

@Test func rpcBashOutputInLlmContext() async throws {
    guard API_KEY != nil else { return }

    let sessionDir = try makeTempDir()
    defer { removeTempDir(sessionDir) }

    try await withRpcClient(sessionDir: sessionDir) { client in
        let uniqueValue = "unique-\(Int(Date().timeIntervalSince1970 * 1000))"
        _ = try await client.bash("echo \(uniqueValue)")
        let events = try await client.promptAndWait(
            "What was the exact output of the echo command I just ran? Reply with just the value, nothing else."
        ).value
        let text = assistantText(from: events)
        #expect(text?.contains(uniqueValue) == true)
    }
}

@Test func rpcSetThinkingLevel() async throws {
    guard API_KEY != nil else { return }

    let sessionDir = try makeTempDir()
    defer { removeTempDir(sessionDir) }

    try await withRpcClient(sessionDir: sessionDir) { client in
        try await client.setThinkingLevel("high")
        let state = try await client.getState().value
        #expect(value(state, "thinkingLevel", as: String.self) == "high")
    }
}

@Test func rpcCycleThinkingLevel() async throws {
    guard API_KEY != nil else { return }

    let sessionDir = try makeTempDir()
    defer { removeTempDir(sessionDir) }

    try await withRpcClient(sessionDir: sessionDir) { client in
        let initialState = try await client.getState().value
        let initialLevel = value(initialState, "thinkingLevel", as: String.self)

        let result = try await client.cycleThinkingLevel()
        #expect(result != nil)
        #expect(result != initialLevel)

        let newState = try await client.getState().value
        #expect(value(newState, "thinkingLevel", as: String.self) == result)
    }
}

@Test func rpcGetAvailableModels() async throws {
    guard API_KEY != nil else { return }

    let sessionDir = try makeTempDir()
    defer { removeTempDir(sessionDir) }

    try await withRpcClient(sessionDir: sessionDir) { client in
        let models = try await client.getAvailableModels().value
        #expect(models.count > 0)
        for model in models {
            let modelValues = model.mapValues { $0.value }
            #expect(modelValues["provider"] is String)
            #expect(modelValues["id"] is String)
            #expect((modelValues["contextWindow"] as? Int ?? 0) > 0)
            #expect(modelValues["reasoning"] is Bool)
        }
    }
}

@Test func rpcGetSessionStats() async throws {
    guard API_KEY != nil else { return }

    let sessionDir = try makeTempDir()
    defer { removeTempDir(sessionDir) }

    try await withRpcClient(sessionDir: sessionDir) { client in
        _ = try await client.promptAndWait("Hello")
        let stats = try await client.getSessionStats().value
        #expect(value(stats, "sessionFile", as: String.self) != nil)
        #expect(value(stats, "sessionId", as: String.self) != nil)
        #expect((value(stats, "userMessages", as: Int.self) ?? 0) >= 1)
        #expect((value(stats, "assistantMessages", as: Int.self) ?? 0) >= 1)
    }
}

@Test func rpcCreateNewSession() async throws {
    guard API_KEY != nil else { return }

    let sessionDir = try makeTempDir()
    defer { removeTempDir(sessionDir) }

    try await withRpcClient(sessionDir: sessionDir) { client in
        _ = try await client.promptAndWait("Hello")
        let state = try await client.getState().value
        #expect((value(state, "messageCount", as: Int.self) ?? 0) > 0)

        _ = try await client.newSession()
        let newState = try await client.getState().value
        #expect(value(newState, "messageCount", as: Int.self) == 0)
    }
}

@Test func rpcExportHtml() async throws {
    guard API_KEY != nil else { return }

    let sessionDir = try makeTempDir()
    defer { removeTempDir(sessionDir) }

    try await withRpcClient(sessionDir: sessionDir) { client in
        _ = try await client.promptAndWait("Hello")
        let path = try await client.exportHtml()
        #expect(path.hasSuffix(".html"))
        #expect(FileManager.default.fileExists(atPath: path))
    }
}

@Test func rpcGetLastAssistantText() async throws {
    guard API_KEY != nil else { return }

    let sessionDir = try makeTempDir()
    defer { removeTempDir(sessionDir) }

    try await withRpcClient(sessionDir: sessionDir) { client in
        let initialText = try await client.getLastAssistantText()
        #expect(initialText == nil)

        _ = try await client.promptAndWait("Reply with just: test123")
        let text = try await client.getLastAssistantText()
        #expect(text?.contains("test123") == true)
    }
}
