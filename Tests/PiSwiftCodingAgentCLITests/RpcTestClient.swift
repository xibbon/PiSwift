import Foundation
import PiSwiftAI
import PiSwiftCodingAgent

struct RpcTestError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

struct SendableJSON: Sendable {
    let value: [String: AnyCodable]
}

struct SendableJSONArray: Sendable {
    let value: [[String: AnyCodable]]
}

actor RpcTestClient {
    struct Options {
        var cliPath: String
        var cwd: String
        var env: [String: String]
        var provider: String
        var model: String
        var args: [String]
    }

    private let options: Options
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdoutTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?
    private var pendingRequests: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var listeners: [UUID: ([String: Any]) -> Void] = [:]
    private var eventWaiters: [UUID: CheckedContinuation<SendableJSONArray, Error>] = [:]
    private var requestId = 0
    private var stderrBuffer = ""
    private var invalidStdoutLines: [String] = []

    init(options: Options) {
        self.options = options
    }

    func start() async throws {
        guard process == nil else {
            throw RpcTestError(message: "RPC client already started")
        }

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: options.cliPath)
        var args = ["--mode", "rpc", "--provider", options.provider, "--model", options.model]
        args.append(contentsOf: options.args)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: options.cwd)
        process.environment = options.env
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        self.process = process
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe

        stdoutTask = Task.detached { [weak self] in
            guard let self else { return }
            do {
                for try await line in stdoutPipe.fileHandleForReading.bytes.lines {
                    await self.handleLine(line)
                }
            } catch {
                await self.appendStderr("stdout error: \(error)")
            }
        }

        stderrTask = Task.detached { [weak self] in
            guard let self else { return }
            do {
                for try await line in stderrPipe.fileHandleForReading.bytes.lines {
                    await self.appendStderr(line + "\n")
                }
            } catch {
                await self.appendStderr("stderr error: \(error)")
            }
        }

        try await Task.sleep(nanoseconds: 100_000_000)

        if !process.isRunning {
            throw RpcTestError(message: "RPC process exited early. Stderr: \(stderrBuffer)")
        }
    }

    func stop() async {
        guard let process else { return }

        stdinPipe?.fileHandleForWriting.closeFile()
        process.terminate()
        await waitForExit(process)

        stdoutTask?.cancel()
        stderrTask?.cancel()

        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: RpcTestError(message: "RPC client stopped"))
        }
        pendingRequests.removeAll()

        for (_, continuation) in eventWaiters {
            continuation.resume(throwing: RpcTestError(message: "RPC client stopped"))
        }
        eventWaiters.removeAll()
        listeners.removeAll()

        self.process = nil
        self.stdinPipe = nil
        self.stdoutPipe = nil
        self.stderrPipe = nil
    }

    func promptAndWait(_ message: String, timeout: TimeInterval = 60) async throws -> SendableJSONArray {
        let eventsTask = Task { try await collectEvents(timeout: timeout) }
        do {
            _ = try await send(["type": "prompt", "message": message])
        } catch {
            eventsTask.cancel()
            throw error
        }
        return try await eventsTask.value
    }

    func getState() async throws -> SendableJSON {
        let response = try await send(["type": "get_state"])
        guard let data = try responseData(response) as? [String: Any] else {
            throw RpcTestError(message: "Invalid get_state response")
        }
        return SendableJSON(value: data.mapValues { AnyCodable($0) })
    }

    func stderrText() -> String {
        stderrBuffer
    }

    func invalidStdoutText() -> [String] {
        invalidStdoutLines
    }

    func compact() async throws -> SendableJSON {
        let response = try await send(["type": "compact"])
        guard let data = try responseData(response) as? [String: Any] else {
            throw RpcTestError(message: "Invalid compact response")
        }
        return SendableJSON(value: data.mapValues { AnyCodable($0) })
    }

    func bash(_ command: String, excludeFromContext: Bool = false) async throws -> SendableJSON {
        let response = try await send([
            "type": "bash",
            "command": command,
            "excludeFromContext": excludeFromContext,
        ])
        guard let data = try responseData(response) as? [String: Any] else {
            throw RpcTestError(message: "Invalid bash response")
        }
        return SendableJSON(value: data.mapValues { AnyCodable($0) })
    }

    func getAvailableModels() async throws -> SendableJSONArray {
        let response = try await send(["type": "get_available_models"])
        guard let data = try responseData(response) as? [String: Any],
              let models = data["models"] as? [[String: Any]] else {
            throw RpcTestError(message: "Invalid get_available_models response")
        }
        return SendableJSONArray(value: models.map { $0.mapValues { AnyCodable($0) } })
    }

    func getSessionStats() async throws -> SendableJSON {
        let response = try await send(["type": "get_session_stats"])
        guard let data = try responseData(response) as? [String: Any] else {
            throw RpcTestError(message: "Invalid get_session_stats response")
        }
        return SendableJSON(value: data.mapValues { AnyCodable($0) })
    }

    func newSession() async throws -> Bool {
        let response = try await send(["type": "new_session"])
        guard let data = try responseData(response) as? [String: Any] else {
            throw RpcTestError(message: "Invalid new_session response")
        }
        return data["cancelled"] as? Bool ?? false
    }

    func exportHtml() async throws -> String {
        let response = try await send(["type": "export_html"])
        guard let data = try responseData(response) as? [String: Any],
              let path = data["path"] as? String else {
            throw RpcTestError(message: "Invalid export_html response")
        }
        return path
    }

    func getLastAssistantText() async throws -> String? {
        let response = try await send(["type": "get_last_assistant_text"])
        guard let data = try responseData(response) as? [String: Any] else {
            throw RpcTestError(message: "Invalid get_last_assistant_text response")
        }
        if data["text"] is NSNull { return nil }
        return data["text"] as? String
    }

    func setThinkingLevel(_ level: String) async throws {
        _ = try await send(["type": "set_thinking_level", "level": level])
    }

    func cycleThinkingLevel() async throws -> String? {
        let response = try await send(["type": "cycle_thinking_level"])
        let data = try responseData(response)
        if data is NSNull { return nil }
        return (data as? [String: Any])?["level"] as? String
    }

    private func collectEvents(timeout: TimeInterval) async throws -> SendableJSONArray {
        var events: [[String: Any]] = []
        return try await withCheckedThrowingContinuation { continuation in
            let token = UUID()
            eventWaiters[token] = continuation
            listeners[token] = { event in
                events.append(event)
                if (event["type"] as? String) == "agent_end" {
                    self.listeners.removeValue(forKey: token)
                    if let waiter = self.eventWaiters.removeValue(forKey: token) {
                        waiter.resume(returning: SendableJSONArray(value: events.map { $0.mapValues { AnyCodable($0) } }))
                    }
                }
            }

            Task.detached { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                } catch {
                    return
                }
                await self?.timeoutEventWaiter(token)
            }
        }
    }

    private func send(_ command: [String: Any], timeout: TimeInterval = 30) async throws -> [String: Any] {
        guard let stdin = stdinPipe?.fileHandleForWriting else {
            throw RpcTestError(message: "RPC client not started")
        }
        requestId += 1
        let id = "req_\(requestId)"
        var payload = command
        payload["id"] = id

        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        do {
            try stdin.write(contentsOf: data)
            try stdin.write(contentsOf: Data([0x0A]))
        } catch {
            throw RpcTestError(message: "Failed to write command: \(error)")
        }

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[id] = continuation
            Task.detached { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                } catch {
                    return
                }
                await self?.timeoutRequest(id)
            }
        }
    }

    private func responseData(_ response: [String: Any]) throws -> Any? {
        guard let success = response["success"] as? Bool else {
            throw RpcTestError(message: "Missing success flag")
        }
        if !success {
            let errorMessage = response["error"] as? String ?? "Unknown error"
            throw RpcTestError(message: "RPC error: \(errorMessage). Stderr: \(stderrBuffer)")
        }
        if response["data"] is NSNull { return nil }
        return response["data"]
    }

    private func handleLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = json as? [String: Any] else {
            invalidStdoutLines.append(line)
            return
        }
        if let type = dict["type"] as? String, type == "response" {
            if let id = dict["id"] as? String, let continuation = pendingRequests.removeValue(forKey: id) {
                continuation.resume(returning: dict)
                return
            }
        }

        let listenersSnapshot = Array(listeners.values)
        for listener in listenersSnapshot {
            listener(dict)
        }
    }

    private func appendStderr(_ text: String) {
        stderrBuffer += text
    }

    private func timeoutRequest(_ id: String) {
        guard let continuation = pendingRequests.removeValue(forKey: id) else { return }
        continuation.resume(throwing: RpcTestError(message: "Timeout waiting for response. Stderr: \(stderrBuffer)"))
    }

    private func timeoutEventWaiter(_ token: UUID) {
        guard let continuation = eventWaiters.removeValue(forKey: token) else { return }
        listeners.removeValue(forKey: token)
        continuation.resume(throwing: RpcTestError(message: "Timeout waiting for agent_end. Stderr: \(stderrBuffer)"))
    }

    private func waitForExit(_ process: Process) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                process.waitUntilExit()
                continuation.resume()
            }
        }
    }
}
