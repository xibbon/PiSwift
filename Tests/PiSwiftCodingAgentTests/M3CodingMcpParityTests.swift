import Foundation
import Testing
import PiSwiftAI
import PiSwiftMCP
@testable import PiSwiftCodingAgent

@Suite("M3 coding-agent MCP parity")
struct M3CodingMcpParityTests {
    @Test("keeps a registered client by default", .timeLimit(.minutes(1)))
    func keepsRegisteredClientByDefault() async throws {
        let server = URL(string: "http://127.0.0.1:45454/mcp")!
        let fixture = McpAuthFixture(issSupported: true, cimd: true)
        let presenter = McpAuthPresenterFixture(iss: "http://127.0.0.1:45454")
        let credentials = McpOAuthCredentialStore(backend: InMemoryAuthStorageBackend())
        let document = URL(string: "https://host.example/oauth/client.json")!
        try await signInMcpServer(name: "work", serverURL: server, credentials: credentials,
            settings: .init(clientRegistration: .dcr), presenter: presenter,
            clientMetadataDocumentURL: document, http: fixture)
        try await signInMcpServer(name: "work", serverURL: server, credentials: credentials,
            presenter: presenter, clientMetadataDocumentURL: document, http: fixture)
        #expect(await presenter.authorizationURLs().count == 1)
        #expect(await fixture.registeredClientNames() == ["pi"])
        let requests = await fixture.recordedTokenRequests()
        #expect(requests.count == 2)
        let refresh = try #require(requests.last)
        #expect(refresh.contains("grant_type=refresh_token"))
        #expect(refresh.contains("client_id=client"))
        #expect(try credentials.state(name: "work", url: server)?.clientInformation?.clientID == "client")
        #expect(try credentials.tokens(name: "work", url: server)?.accessToken == "refreshed")
    }

    @Test("points resource links to read_mcp_resource and saves binary resources")
    func convertsResourceLinksAndBinaryResources() async throws {
        let saved = LockedState<[(Data, String)]>([])
        let result = McpToolResult(content: [
            .init(type: "resource_link", mimeType: "text/markdown", uri: "docs://guide",
                name: "guide", title: "The Guide", description: "How to use it", size: 2048),
            .init(type: "resource", resource: .init(uri: "file:///r/report.pdf",
                blob: "JVBERg==", mimeType: "application/pdf")),
            .init(type: "resource", resource: .init(uri: "docs://logo",
                blob: "AAAA", mimeType: "image/png")),
        ])
        let converted = await convertMcpResult(server: "docs", tool: "t", result: result,
            readableResources: true, saveOutput: { data, ext in
                saved.withLock { $0.append((data, ext)) }
                return URL(fileURLWithPath: "/tmp/saved.pdf")
            })
        #expect(converted.content.count == 3)
        guard case .text(let link) = converted.content[0],
              case .text(let binary) = converted.content[1] else {
            Issue.record("Expected resource text")
            return
        }
        #expect(link.text == "[Resource docs://guide \"The Guide\" (text/markdown, 2.0KB): How to use it. Read it with read_mcp_resource (server \"docs\")]")
        #expect(binary.text == "[Binary resource file:///r/report.pdf (application/pdf, 4B) saved to /tmp/saved.pdf]")
        guard case .image(let image) = converted.content[2] else {
            Issue.record("Expected an image resource")
            return
        }
        #expect(image.data == "AAAA")
        #expect(image.mimeType == "image/png")
        #expect(saved.withLock { $0.count } == 1)
        #expect(saved.withLock { $0.first?.0 } == Data("%PDF".utf8))
        #expect(saved.withLock { $0.first?.1 } == ".pdf")
        let script = try #require(converted.structuredContent?.value as? [String: Any])
        let blocks = try #require(script["content"] as? [[String: Any]])
        #expect(blocks.count == 3)
        #expect(blocks[0]["uri"] as? String == "docs://guide")
        #expect((blocks[1]["resource"] as? [String: Any])?["blob"] as? String == "JVBERg==")
    }

    @Test("cuts the middle of model-facing text over 20KB and keeps the full result for scripts")
    func truncatesModelTextAndKeepsScriptResult() async throws {
        let full = (1...3000).map { "line \($0)" }.joined(separator: "\n")
        let saved = LockedState<[Data]>([])
        let result = McpToolResult(content: [.init(type: "text", text: full),
            .init(type: "image", data: "AAAA", mimeType: "image/png")])
        let converted = await convertMcpResult(server: "docs", tool: "snapshot", result: result,
            saveOutput: { data, _ in
                saved.withLock { $0.append(data) }
                return URL(fileURLWithPath: "/tmp/full.txt")
            })
        #expect(converted.content.count == 2)
        guard case .text(let block) = converted.content[0] else {
            Issue.record("Expected truncated text")
            return
        }
        let text = block.text
        #expect(text.hasPrefix("Warning: truncated output (original token count: \(Int(ceil(Double(full.count) / 4))))\nTotal output lines: 3000\n\nline 1\nline 2\n"))
        #expect(text.contains(/…\d+ chars truncated…/))
        #expect(text.hasSuffix("line 3000\n\n[Full output: /tmp/full.txt (read it with offset/limit)]"))
        #expect(text.utf8.count < 21 * 1024)
        guard case .image(let image) = converted.content[1] else {
            Issue.record("Expected the original image")
            return
        }
        #expect(image.data == "AAAA")
        #expect(image.mimeType == "image/png")
        let details = try #require(converted.details?.value as? [String: Any])
        #expect(details["server"] as? String == "docs")
        #expect(details["tool"] as? String == "snapshot")
        #expect(details["fullOutputPath"] as? String == "/tmp/full.txt")
        #expect(saved.withLock { $0 } == [Data(full.utf8)])
        let script = try #require(converted.structuredContent?.value as? [String: Any])
        let blocks = try #require(script["content"] as? [[String: Any]])
        #expect(blocks.count == 2)
        #expect(blocks[0]["text"] as? String == full)
        #expect(blocks[1]["data"] as? String == "AAAA")
        _ = await convertMcpResult(server: "docs", tool: "small",
            result: .init(content: [.init(type: "text", text: "ok")]), saveOutput: { data, _ in
                saved.withLock { $0.append(data) }
                return URL(fileURLWithPath: "/tmp/full.txt")
            })
        #expect(saved.withLock { $0.count } == 1)
    }
}
