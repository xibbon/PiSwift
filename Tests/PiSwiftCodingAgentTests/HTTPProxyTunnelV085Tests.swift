import Foundation
import Testing
@testable import PiSwiftAI
#if os(macOS)
import Darwin

private enum TunnelTestError: Error {
    case socket, bind, listen, timeout, accept, read, write, wrongRequest(String)
}

private func tunnelTestListener() throws -> (fd: Int32, port: UInt16) {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw TunnelTestError.socket }
    do {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw TunnelTestError.bind }
        guard Darwin.listen(fd, 4) == 0 else { throw TunnelTestError.listen }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { throw TunnelTestError.bind }
        return (fd, UInt16(bigEndian: address.sin_port))
    } catch {
        close(fd)
        throw error
    }
}

private func tunnelTestAccept(_ listener: Int32) throws -> Int32 {
    var event = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
    guard poll(&event, 1, 5_000) > 0 else { throw TunnelTestError.timeout }
    let client = accept(listener, nil, nil)
    guard client >= 0 else { throw TunnelTestError.accept }
    var noSignal: Int32 = 1
    _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    return client
}

private func tunnelTestRead(_ fd: Int32) throws -> String {
    var data = Data()
    while !data.suffix(4).elementsEqual([13, 10, 13, 10]) {
        var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&event, 1, 5_000) > 0 else { throw TunnelTestError.timeout }
        var bytes = [UInt8](repeating: 0, count: 4_096)
        let count = recv(fd, &bytes, bytes.count, 0)
        guard count > 0 else { throw TunnelTestError.read }
        data.append(contentsOf: bytes.prefix(count))
        guard data.count < 65_536 else { throw TunnelTestError.read }
    }
    return String(decoding: data, as: UTF8.self)
}

private func tunnelTestWrite(_ fd: Int32, _ text: String) throws {
    let bytes = Array(text.utf8)
    try bytes.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
            let count = send(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
            guard count > 0 else { throw TunnelTestError.write }
            offset += count
        }
    }
}

@Test(arguments: [false, true])
func codingAgent085HTTPProxyUsesCONNECT(authentication: Bool) async throws {
    let listener = try tunnelTestListener()
    defer { close(listener.fd) }
    let server = Task.detached { () throws -> [String] in
        var requests: [String] = []
        if authentication {
            let first = try tunnelTestAccept(listener.fd)
            defer { close(first) }
            let request = try tunnelTestRead(first)
            requests.append(request.components(separatedBy: "\r\n")[0])
            try tunnelTestWrite(first, "HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"test\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            shutdown(first, SHUT_RDWR)
        }
        let client = try tunnelTestAccept(listener.fd)
        defer { close(client) }
        let connect = try tunnelTestRead(client)
        let line = connect.components(separatedBy: "\r\n")[0]
        guard line == "CONNECT origin.invalid:80 HTTP/1.1" else { throw TunnelTestError.wrongRequest(line) }
        if authentication {
            #expect(connect.lowercased().contains("proxy-authorization: basic dGVzdC11c2VyOnRlc3QtcGFzcw==".lowercased()))
        }
        requests.append(line)
        try tunnelTestWrite(client, "HTTP/1.1 200 Connection Established\r\n\r\n")
        let origin = try tunnelTestRead(client)
        requests.append(origin.components(separatedBy: "\r\n")[0])
        try tunnelTestWrite(client, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
        return requests
    }
    let credentials = authentication ? "test-user:test-pass@" : ""
    let url = try #require(URL(string: "http://\(credentials)127.0.0.1:\(listener.port)"))
    let session = try #require(makeHTTPConnectProxySession(proxyURL: url))
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: URL(string: "http://origin.invalid/probe")!)
    request.timeoutInterval = 5
    let (data, _) = try await session.data(for: request)
    #expect(String(decoding: data, as: UTF8.self) == "ok")
    let captured = try await server.value
    #expect(captured.first == "CONNECT origin.invalid:80 HTTP/1.1")
    #expect(captured.last == "GET /probe HTTP/1.1")
    #expect(captured.count == (authentication ? 3 : 2))
}

@Test func codingAgent085ProxySelectionUsesDestinationScheme() {
    let env = ["HTTP_PROXY": "http://http-proxy.invalid:8080", "HTTPS_PROXY": "https://https-proxy.invalid:8443"]
    #expect(selectedProxyURL(for: URL(string: "http://origin.invalid"), env: env)?.host == "http-proxy.invalid")
    #expect(selectedProxyURL(for: URL(string: "https://origin.invalid"), env: env)?.host == "https-proxy.invalid")
    #expect(selectedProxyURL(for: URL(string: "https://origin.invalid"), env: ["ALL_PROXY": "proxy.invalid:8080"])?.absoluteString == "http://proxy.invalid:8080")
}
#endif
