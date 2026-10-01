import Foundation

struct OAuthCallbackFailure: Error, LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

enum OAuthCallbackOrManual<Value: Sendable>: Sendable {
    case callback(Value)
    case manual(String)
}

#if canImport(Network)
import Network

public enum OAuthCallbackMode: Sendable, Equatable {
    case standard
    // pi-mono v0.99.1 uses a distinct handler for ChatGPT. It keeps waiting
    // after invalid state, code, or client_id callbacks and has no 409 rule.
    case chatGPT
}

public actor OAuthCallbackServer<Value: Sendable> {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "pi.oauth.callback")
    private let providerName: String
    private let path: String
    private let state: String?
    private let redirectHost: String
    private let mode: OAuthCallbackMode
    private let complete: @Sendable (URLComponents) async throws -> Value
    private var claimed = false
    private var settled: Result<Value?, Error>?
    private var waiters: [CheckedContinuation<Value?, Error>] = []
    private var timeoutTask: Task<Void, Never>?
    private var removeCancellationHandler: (@Sendable () -> Void)?
    private var connections: [NWConnection] = []
    private var boundPort: UInt16?

    private init(
        listener: NWListener, providerName: String, path: String, state: String?,
        redirectHost: String, mode: OAuthCallbackMode,
        complete: @escaping @Sendable (URLComponents) async throws -> Value
    ) {
        self.listener = listener
        self.providerName = providerName
        self.path = path
        self.state = state
        self.redirectHost = redirectHost
        self.mode = mode
        self.complete = complete
    }

    public static func start(
        providerName: String, host: String = "127.0.0.1", port: UInt16,
        path: String, redirectHost: String? = nil, state: String? = nil,
        mode: OAuthCallbackMode = .standard, signal: CancellationToken? = nil,
        timeoutMs: Int? = nil,
        complete: @escaping @Sendable (URLComponents) async throws -> Value
    ) async throws -> OAuthCallbackServer<Value> {
        if signal?.isCancelled == true { throw OAuthCallbackFailure(message: "Login cancelled") }
        let nwPort = NWEndpoint.Port(rawValue: port) ?? .any
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: nwPort)
        let listener = try NWListener(using: parameters, on: nwPort)
        let server = OAuthCallbackServer(
            listener: listener, providerName: providerName, path: path, state: state,
            redirectHost: redirectHost ?? host, mode: mode, complete: complete
        )
        try await server.startListener()
        if let signal {
            let remove = signal.onCancel { Task { await server.abort() } }
            await server.setCancellationHandler(remove)
        }
        if let timeoutMs {
            await server.startTimeout(milliseconds: timeoutMs)
        }
        return server
    }

    public func redirectUri() -> String {
        let host = redirectHost.contains(":") ? "[\(redirectHost)]" : redirectHost
        return "http://\(host):\(boundPort ?? 0)\(path)"
    }

    public func wait() async throws -> Value? {
        try await withCheckedThrowingContinuation { continuation in
            if let settled {
                continuation.resume(with: settled)
            } else {
                waiters.append(continuation)
            }
        }
    }

    @discardableResult func cancel() -> Bool {
        guard !claimed, settled == nil else { return false }
        finish(.success(nil))
        return true
    }

    public func close() {
        finish(.failure(OAuthCallbackFailure(message: "OAuth callback server closed")))
        listener.cancel()
        for connection in connections { connection.cancel() }
        connections.removeAll()
    }

    private func abort() { finish(.failure(OAuthCallbackFailure(message: "Login cancelled"))) }
    private func listenerFailed(_ error: Error) { finish(.failure(error)) }

    private func setCancellationHandler(_ remove: @escaping @Sendable () -> Void) {
        removeCancellationHandler = remove
    }

    private func startTimeout(milliseconds: Int) {
        timeoutTask = Task {
            try? await Task.sleep(for: .milliseconds(milliseconds))
            if !Task.isCancelled { finish(.failure(OAuthCallbackFailure(message: "\(providerName) sign-in timed out"))) }
        }
    }

    private func finish(_ result: Result<Value?, Error>) {
        guard settled == nil else { return }
        settled = result
        timeoutTask?.cancel()
        removeCancellationHandler?()
        removeCancellationHandler = nil
        for waiter in waiters { waiter.resume(with: result) }
        waiters.removeAll()
    }

    private func startListener() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = LockedState(false)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard let self else { return }
                    Task {
                        await self.setBoundPort()
                        if resumed.withLock({ value in if value { return false }; value = true; return true }) {
                            continuation.resume()
                        }
                    }
                case .failed(let error):
                    if resumed.withLock({ value in if value { return false }; value = true; return true }) {
                        continuation.resume(throwing: error)
                    } else {
                        Task { await self?.listenerFailed(error) }
                    }
                case .cancelled:
                    if resumed.withLock({ value in if value { return false }; value = true; return true }) {
                        continuation.resume(throwing: OAuthCallbackFailure(message: "OAuth callback server closed"))
                    }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { await self?.handle(connection) }
            }
            listener.start(queue: queue)
        }
    }

    private func setBoundPort() { boundPort = listener.port?.rawValue }

    private final class ConnectionState: Sendable {
        let buffer = LockedState(Data())
    }

    private func handle(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        receive(connection, state: ConnectionState())
    }

    private func receive(_ connection: NWConnection, state: ConnectionState) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, _ in
            var requestLine: String?
            state.buffer.withLock { buffer in
                if let data { buffer.append(data) }
                if let range = buffer.range(of: Data("\r\n".utf8)) {
                    requestLine = String(data: buffer[..<range.lowerBound], encoding: .utf8)
                }
            }
            if let requestLine {
                Task { await self?.process(requestLine, connection: connection) }
            } else if isComplete {
                connection.cancel()
            } else {
                Task { await self?.receive(connection, state: state) }
            }
        }
    }

    private func process(_ line: String, connection: NWConnection) async {
        let parts = line.split(separator: " ")
        guard parts.count >= 2,
              let components = URLComponents(string: "http://localhost\(parts[1])") else {
            await send(connection, status: 400, html: OAuthPage.error("Bad request."))
            return
        }
        if components.path != path || (mode == .standard && parts[0] != "GET") {
            await send(connection, status: 404, html: OAuthPage.error("Callback route not found."))
            return
        }
        let parameter: (String) -> String? = { name in components.queryItems?.first { $0.name == name }?.value }
        if mode == .standard {
            if let state, parameter("state") != state {
                await send(connection, status: 400, html: OAuthPage.error("State mismatch."))
                return
            }
            if claimed || settled != nil {
                await send(connection, status: 409, html: OAuthPage.error("This sign-in has already been handled."))
                return
            }
            if let error = parameter("error"), !error.isEmpty {
                let detail = parameter("error_description") ?? error
                claimed = true
                await send(connection, status: 400, html: OAuthPage.error("\(providerName) authorization failed.", details: detail))
                finish(.failure(OAuthCallbackFailure(message: "\(providerName) authorization failed: \(detail)")))
                return
            }
            guard let code = parameter("code"), !code.isEmpty else {
                await send(connection, status: 400, html: OAuthPage.error("Missing authorization code."))
                return
            }
            claimed = true
            do {
                let value = try await complete(components)
                await send(connection, status: 200, html: OAuthPage.success("Signed in to \(providerName). You may now close this page."))
                finish(.success(value))
            } catch {
                await send(connection, status: 502, html: OAuthPage.error("\(providerName) sign-in failed.", details: error.localizedDescription))
                finish(.failure(error))
            }
        } else {
            if let error = parameter("error"), !error.isEmpty {
                claimed = true
                await send(connection, status: 400, html: OAuthPage.error("ChatGPT was not connected.", details: "Error: \(error)"))
                finish(.failure(OAuthCallbackFailure(message: "ChatGPT authorization failed: \(error)")))
                return
            }
            do {
                let value = try await complete(components)
                claimed = true
                await send(connection, status: 200, html: OAuthPage.success("ChatGPT authentication completed. You can close this window."))
                finish(.success(value))
            } catch {
                // Upstream keeps the listener and wait alive after an invalid callback.
                await send(connection, status: 400, html: OAuthPage.error(error.localizedDescription))
            }
        }
    }

    private func send(_ connection: NWConnection, status: Int, html: String) async {
        let body = Data(html.utf8)
        var headerLines = [
            "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")",
            "Content-Type: text/html; charset=utf-8",
            "Content-Length: \(body.count)",
        ]
        if mode == .standard { headerLines.append("Cache-Control: no-store") }
        headerLines.append(contentsOf: ["Connection: close", "", ""])
        let header = headerLines.joined(separator: "\r\n")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in
                connection.cancel()
                continuation.resume()
            })
        }
    }
}

/// A continuation race. The callback server and prompt can both finish first.
func waitForCallbackOrManualInput<Value: Sendable>(
    callbacks: OAuthLoginCallbacks, callback: OAuthCallbackServer<Value>?, prompt: OAuthPrompt
) async throws -> OAuthCallbackOrManual<Value> {
    guard let callback else {
        if let manual = callbacks.onManualCodeInput { return .manual(try await manual() ?? "") }
        return .manual(try await callbacks.onPrompt(prompt))
    }
    let resolved = LockedState(false)
    let manualFailure = LockedState<String?>(nil)
    return try await withCheckedThrowingContinuation { continuation in
        func settle(_ result: Result<OAuthCallbackOrManual<Value>, Error>) {
            if resolved.withLock({ value in if value { return false }; value = true; return true }) {
                continuation.resume(with: result)
            }
        }
        let manual = Task {
            do {
                let input: String
                if let provider = callbacks.onManualCodeInput {
                    input = try await provider() ?? ""
                } else {
                    input = try await callbacks.onPrompt(prompt)
                }
                if await callback.cancel() { settle(.success(.manual(input))) }
            } catch {
                manualFailure.withLock { $0 = error.localizedDescription }
                if await callback.cancel() { settle(.failure(error)) }
            }
        }
        Task {
            do {
                if let value = try await callback.wait() {
                    manual.cancel()
                    if let message = manualFailure.withLock({ $0 }) {
                        settle(.failure(OAuthCallbackFailure(message: message)))
                    } else {
                        settle(.success(.callback(value)))
                    }
                }
            } catch {
                manual.cancel()
                settle(.failure(error))
            }
        }
    }
}
#endif
