import Foundation
import CryptoKit
import Testing
import PiSwiftMCP
@testable import PiSwiftCodingAgent
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private let m3DiskServer = URL(string: "https://mcp.example.com/mcp")!
private let m3DiskRedirect = URL(string: "https://app.example.com/oauth/callback")!

private actor M3DiskTokenHTTP: McpOAuthHTTPClient {
    private var requests: [String] = []
    private var released = false

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        #expect(request.url?.path == "/token")
        requests.append(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
        while !released { try await Task.sleep(for: .milliseconds(1)) }
        let data = Data(#"{"access_token":"fresh-access","refresh_token":"rotated-refresh","token_type":"Bearer","expires_in":3600}"#.utf8)
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!)
    }
    func count() -> Int { requests.count }
    func bodies() -> [String] { requests }
    func release() { released = true }
}

private func m3DiskDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("m3-disk-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func m3DiskSeed(_ store: McpOAuthCredentialStore, name: String = "work") async throws {
    let metadata = McpOAuthAuthorizationServerMetadata(issuer: "https://auth.example.com",
        authorizationEndpoint: "https://auth.example.com/authorize",
        tokenEndpoint: "https://auth.example.com/token")
    try await store.forServer(name: name, url: m3DiskServer).save(McpOAuthState(
        serverURL: m3DiskServer.absoluteString,
        clientInformation: .init(clientID: "registered-client",
            metadata: .init(redirectURIs: [m3DiskRedirect.absoluteString])),
        tokens: .init(accessToken: "old-access", tokenType: "Bearer", refreshToken: "old-refresh"),
        tokensExpireAt: .distantPast,
        discovery: .init(authorizationServerURL: "https://auth.example.com",
            authorizationServerMetadata: metadata)))
}

@Test(.timeLimit(.minutes(1)))
func m3DiskRefreshSharesRequestAndSavesRotationBeforeSecondRead() async throws {
    let directory = try m3DiskDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = McpOAuthCredentialStore(agentDir: directory)
    try await m3DiskSeed(store)
    let http = M3DiskTokenHTTP()
    let first = McpServerAuthProvider(name: "work", serverURL: m3DiskServer,
        credentials: store, redirectURL: m3DiskRedirect, http: http)
    let second = McpServerAuthProvider(name: "work", serverURL: m3DiskServer,
        credentials: McpOAuthCredentialStore(agentDir: directory), redirectURL: m3DiskRedirect, http: http)
    let firstRead = Task { try await first.token() }
    while await http.count() == 0 { try await Task.sleep(for: .milliseconds(1)) }
    let secondRead = Task { try await second.token() }
    await http.release()
    #expect(try await firstRead.value == "fresh-access")
    #expect(try await secondRead.value == "fresh-access")
    #expect(await http.count() == 1)
    #expect(await http.bodies().first?.contains("refresh_token=old-refresh") == true)
    let reopened = McpOAuthCredentialStore(agentDir: directory)
    #expect(try reopened.tokens(name: "work", url: m3DiskServer)?.refreshToken == "rotated-refresh")
    let disk = try String(contentsOf: directory.appendingPathComponent("mcp-auth.json"), encoding: .utf8)
    #expect(disk.contains("rotated-refresh"))
    #expect(!disk.contains("old-refresh"))
}

@Test
func m3DiskCrossProcessBusyLockSkipsSignInRefresh() async throws {
    let directory = try m3DiskDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = McpOAuthCredentialStore(agentDir: directory)
    try await m3DiskSeed(store, name: "busy-work")
    let key = "mcp__busy_work|" + m3DiskServer.absoluteString
    let hash = SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    let lockPath = directory.appendingPathComponent("mcp-auth-refresh-\(hash)").path
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", "-c", "import fcntl,sys; f=open(sys.argv[1],'a'); fcntl.flock(f,fcntl.LOCK_EX); print('R',flush=True); sys.stdin.read(1)", lockPath]
    process.standardInput = input
    process.standardOutput = output
    // `waitUntilExit()` can wait forever in an async test (it hung the serial suite twice);
    // the termination handler is set before `run()`, so the exit is never missed.
    let (exits, exited) = AsyncStream.makeStream(of: Int32.self, bufferingPolicy: .bufferingNewest(1))
    process.terminationHandler = { finished in
        exited.yield(finished.terminationStatus)
        exited.finish()
    }
    try process.run()
    defer {
        // A child can inherit the pipe's write end, so end-of-file cannot release the lock.
        if process.isRunning {
            try? input.fileHandleForWriting.write(contentsOf: Data("Q".utf8))
            process.terminate()
        }
    }
    try #require(output.fileHandleForReading.read(upToCount: 1) == Data("R".utf8))
    let http = M3DiskTokenHTTP()
    let options = McpSignInOptions(serverURL: m3DiskServer, redirectURL: m3DiskRedirect,
        store: store.forServer(name: "busy-work", url: m3DiskServer), clientID: "registered-client", http: http)
    let result = try await McpOAuthSignIn.startMcpSignIn(options: options)
    guard case .redirect(let authorization) = result else {
        Issue.record("Busy refresh lock must lead to the browser step")
        return
    }
    #expect(authorization.authorizationURL.host == "auth.example.com")
    #expect(await http.count() == 0)
    #expect(try store.tokens(name: "busy-work", url: m3DiskServer)?.refreshToken == "old-refresh")
    try input.fileHandleForWriting.write(contentsOf: Data("Q".utf8))
    var status: Int32?
    for await value in exits { status = value }
    #expect(status == 0)
}
