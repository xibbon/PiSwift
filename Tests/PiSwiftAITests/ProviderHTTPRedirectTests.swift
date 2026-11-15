#if os(macOS)
import Foundation
import Network
import Testing
@testable import PiSwiftAI

/// A local HTTP server: `/start` answers 302 to `/target`; `/target` answers 200.
private final class RedirectServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "redirect-server")
    let targetHits = LockedState(0)

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
    }

    func start() async throws -> UInt16 {
        let ready = LockedState<CheckedContinuation<UInt16, Error>?>(nil)
        return try await withCheckedThrowingContinuation { continuation in
            ready.withLock { $0 = continuation }
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    ready.withLock { $0.take() }?.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    ready.withLock { $0.take() }?.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let response: String
            if request.hasPrefix("GET /target") {
                self?.targetHits.withLock { $0 += 1 }
                response = "HTTP/1.1 200 OK\r\nContent-Length: 8\r\nConnection: close\r\n\r\nfollowed"
            } else {
                response = "HTTP/1.1 302 Found\r\nLocation: /target\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            }
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

@Suite("Provider HTTP redirects", .timeLimit(.minutes(1)))
struct ProviderHTTPRedirectTests {
    @Test func redirectIsReturnedWhenFollowingIsOff() async throws {
        let server = try RedirectServer()
        defer { server.stop() }
        let port = try await server.start()
        let request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/start")!)

        let refused = try await DefaultProviderHTTPClient(env: ["NO_PROXY": "*"], followRedirects: false).send(request)
        #expect(refused.statusCode == 302)
        #expect(server.targetHits.withLock { $0 } == 0)

        // Control: the default client follows the same redirect.
        let followed = try await DefaultProviderHTTPClient(env: ["NO_PROXY": "*"]).send(request)
        #expect(followed.statusCode == 200)
        #expect(server.targetHits.withLock { $0 } == 1)
    }
}
#endif
