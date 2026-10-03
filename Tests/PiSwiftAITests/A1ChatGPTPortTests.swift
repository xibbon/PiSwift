import Foundation
import Testing
@testable import PiSwiftAI

#if canImport(Network) && canImport(CryptoKit)
import Darwin
import Network

@Suite("A1 ChatGPT occupied callback port", .timeLimit(.minutes(1)))
struct A1ChatGPTPortTests {
    @Test func otherStartupErrorsPropagateBeforeAuthOrPaste() async {
        let signal = CancellationToken()
        signal.cancel()
        let calls = LockedState(0)
        let callbacks = OAuthLoginCallbacks(
            onAuth: { _ in calls.withLock { $0 += 1 } },
            onPrompt: { _ in calls.withLock { $0 += 1 }; return "unused" },
            onProgress: { _ in calls.withLock { $0 += 1 } },
            signal: signal, getDeviceId: { "00000000-0000-4000-8000-000000000001" }
        )
        do {
            _ = try await loginOpenAIChatGPT(callbacks, callbackPort: 1455)
            Issue.record("Expected startup cancellation")
        } catch {
            #expect(error is OAuthCallbackFailure)
            #expect(error.localizedDescription == "Login cancelled")
        }
        #expect(calls.withLock { $0 } == 0)
    }
    @Test func occupiedFixedPortFailsBeforeAuthOrPaste() async throws {
        // Use the A5CallbackServerTests fixed-port method: bind a free port,
        // keep the socket open, then start login with that same port.
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        #expect(descriptor >= 0)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        #expect(bound == 0)
        guard bound == 0 else { return }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let read = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        #expect(read == 0)
        guard read == 0 else { return }
        let port = UInt16(bigEndian: address.sin_port)
        #expect(port != 0)
        #expect(Darwin.listen(descriptor, 1) == 0)
        let authCalls = LockedState(0)
        let promptCalls = LockedState(0)
        let progressCalls = LockedState(0)
        let callbacks = OAuthLoginCallbacks(
            onAuth: { _ in authCalls.withLock { $0 += 1 } },
            onPrompt: { _ in promptCalls.withLock { $0 += 1 }; return "unused" },
            onProgress: { _ in progressCalls.withLock { $0 += 1 } },
            getDeviceId: { "00000000-0000-4000-8000-000000000001" }
        )
        do {
            _ = try await loginOpenAIChatGPT(callbacks, callbackPort: port)
            Issue.record("Expected occupied port failure")
        } catch {
            guard case .callbackPortInUse(let actualPort) = error as? OAuthError else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(actualPort == port)
            #expect(error.localizedDescription == "Port \(port) is in use, probably by an unfinished login in another pi session or by the Codex CLI. Cancel that login and try again.")
        }
        #expect(authCalls.withLock { $0 } == 0)
        #expect(promptCalls.withLock { $0 } == 0)
        #expect(progressCalls.withLock { $0 } == 0)
    }
}
#endif
