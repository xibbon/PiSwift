import Foundation
import Network
import PiSwiftAI

/// JSON-lines MCP transport for an explicit Unix-domain socket endpoint.
/// It is available on Apple platforms that provide the Network framework.
public actor UnixSocketTransport: McpTransport {
    private let path: String
    private var connection: NWConnection?
    private var buffer = Data()
    private var closed = false

    public init(path: String) {
        self.path = path
    }

    public func start() async throws {
        guard connection == nil else {
            throw McpError.connectionFailed("Unix socket transport has already started")
        }
        let connection = NWConnection(to: .unix(path: path), using: .tcp)
        self.connection = connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let didResume = LockedState(false)
            connection.stateUpdateHandler = { state in
                let shouldResume = didResume.withLock { value in
                    guard !value else { return false }
                    value = true
                    return true
                }
                guard shouldResume else { return }
                switch state {
                case .ready:
                    continuation.resume()
                case .failed(let error):
                    continuation.resume(throwing: McpError.connectionFailed(error.localizedDescription))
                case .cancelled:
                    continuation.resume(throwing: McpError.transportClosed)
                default:
                    didResume.withLock { $0 = false }
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    public func send(_ data: Data) async throws {
        guard !closed, let connection else { throw McpError.transportClosed }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: McpError.connectionFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    public func receive() async throws -> Data {
        while true {
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if !line.isEmpty { return line }
                continue
            }
            buffer.append(try await receiveChunk())
        }
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        connection?.cancel()
        connection = nil
        buffer.removeAll(keepingCapacity: false)
    }

    private func receiveChunk() async throws -> Data {
        guard !closed, let connection else { throw McpError.transportClosed }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                if let error {
                    continuation.resume(throwing: McpError.connectionFailed(error.localizedDescription))
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if complete {
                    continuation.resume(throwing: McpError.transportClosed)
                } else {
                    continuation.resume(throwing: McpError.transportClosed)
                }
            }
        }
    }
}
