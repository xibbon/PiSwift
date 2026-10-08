import Foundation
import Testing
@testable import PiSwiftAI

#if canImport(Network)
import Darwin

private enum C2CallbackOriginFailure: Error, Sendable {
    case socket
    case bind
    case port
    case url
}

private func c2FreeCallbackPort() throws -> UInt16 {
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw C2CallbackOriginFailure.socket }
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
    guard bound == 0 else { throw C2CallbackOriginFailure.bind }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let read = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.getsockname(descriptor, $0, &length)
        }
    }
    guard read == 0 else { throw C2CallbackOriginFailure.port }
    return UInt16(bigEndian: address.sin_port)
}

@Suite("C2 OAuth callback origin", .timeLimit(.minutes(1)))
struct C2OAuthCallbackOriginTests {
    @Test(arguments: [false, true])
    func completionURLUsesRedirectHostAndBoundPort(useFixedPort: Bool) async throws {
        let requestedPort = try useFixedPort ? c2FreeCallbackPort() : 0
        let path = "/oauth/callback/origin"
        let query = "state=origin-state&code=code%2Bwith%20space&scope=first&scope=second"
        let server = try await OAuthCallbackServer<String>.start(
            providerName: "Origin", host: "127.0.0.1", port: requestedPort,
            path: path, redirectHost: "localhost", state: "origin-state",
            timeoutMs: 10_000
        ) { components in
            guard let url = components.url else { throw C2CallbackOriginFailure.url }
            return url.absoluteString
        }
        defer { Task { await server.close() } }

        let redirect = await server.redirectUri()
        let redirectComponents = try #require(URLComponents(string: redirect))
        let boundPort = try #require(redirectComponents.port)
        #expect(boundPort > 0)
        if useFixedPort { #expect(boundPort == Int(requestedPort)) }

        // Use the bind address for the request. The completion must use the redirect host.
        var requestComponents = redirectComponents
        requestComponents.host = "127.0.0.1"
        requestComponents.percentEncodedQuery = query
        let requestURL = try #require(requestComponents.url)
        var request = URLRequest(url: requestURL)
        request.timeoutInterval = 10
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)

        let completedURL = try #require(try await server.wait())
        let completed = try #require(URLComponents(string: completedURL))
        #expect(completedURL == redirect + "?" + query)
        #expect(completed.scheme == "http")
        #expect(completed.host == "localhost")
        #expect(completed.port == boundPort)
        #expect(completed.path == path)
        #expect(completed.percentEncodedQuery == query)
        #expect(completed.queryItems == [
            URLQueryItem(name: "state", value: "origin-state"),
            URLQueryItem(name: "code", value: "code+with space"),
            URLQueryItem(name: "scope", value: "first"),
            URLQueryItem(name: "scope", value: "second"),
        ])
        await server.close()
    }
}
#endif
