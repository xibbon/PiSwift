import Foundation
import PiSwiftAI
import PiSwiftMCP
import Testing

@Suite("Remaining v1.5.2 MCP helper cases")
struct M3HelperParityTests {
    private func error(_ value: Any) -> String {
        if case .invalid(let message) = validateMcpServerConfig(name: "s", value: value) { return message }
        return ""
    }

    @Test func inputSchemaKeepsDefinitionsAndAddsProperties() {
        let typed = normalizeMcpInputSchema(["type": "object"])
        #expect((typed["properties"] as? [String: Any])?.isEmpty == true)
        let result = normalizeMcpInputSchema(["properties": ["a": [:]], "$defs": ["x": [:]]])
        #expect(result["type"] as? String == "object")
        #expect((result["$defs"] as? [String: Any])?["x"] != nil)
    }

    @Test func configReportsRemainingInvalidFields() {
        let cases: [(Any, String)] = [
            ("npx", "server \"s\" must be an object"),
            ([Any](), "server \"s\" must be an object"),
            (["command": "x", "description": 1], "server \"s\": description must be a string"),
            (["command": "x", "timeout": 0], "server \"s\": timeout must be a positive number of seconds"),
            (["command": "x", "args": "a b"], "server \"s\": args must be an array of strings"),
            (["command": "x", "env": ["A": 1]], "server \"s\": env must map names to strings"),
            (["command": "x", "cwd": 1], "server \"s\": cwd must be a string"),
            (["url": "not a url"], "server \"s\": url must be an http or https URL"),
            (["url": "https://a.example", "headers": ["A": 1]], "server \"s\": headers must map names to strings"),
            ([String: Any](), "server \"s\" needs either \"command\" (stdio) or \"url\" (streamable HTTP)"),
            (["type": "http", "command": "x"], "server \"s\" needs either \"command\" (stdio) or \"url\" (streamable HTTP)")
        ]
        for (value, expected) in cases { #expect(error(value) == expected) }
    }

    @Test func configKeepsTransportFieldsAndAliases() {
        let fields: [String: Any] = ["command": "npx", "args": ["-y", "server"], "env": ["A": "1"], "cwd": "sub", "enabled": false]
        if case .stdio(let result) = validateMcpServerConfig(name: "files", value: fields) {
            #expect(result.fields["env"] as? [String: String] == ["A": "1"])
            #expect(result.fields["cwd"] as? String == "sub")
            #expect(result.fields["enabled"] as? Bool == false)
        } else { Issue.record("Expected stdio") }
        for type in ["http", "streamable-http"] {
            if case .http = validateMcpServerConfig(name: "docs", value: ["type": type, "url": "http://localhost:3000/mcp"]) {} else { Issue.record("Expected HTTP") }
        }
        #expect(isMcpServerOverride([:]))
        #expect(!isMcpServerOverride(["url": "https://a.example"]))
        #expect(!isMcpServerOverride(["type": "stdio", "enabled": false]))
    }

    @Test func oauthReportsRemainingFields() {
        let cases: [(Any, String)] = [
            ("x", "oauth must be an object"),
            (["clientId": 1], "oauth.clientId must be a string"),
            (["clientSecret": 1], "oauth.clientSecret must be a string"),
            (["scope": 1], "oauth.scope must be a string"),
            (["clientRegistration": "x"], "oauth.clientRegistration must be \"dcr\" or \"cimd\""),
            (["callbackUrl": "http://localhost:8080/cb", "callbackPort": 9090], "oauth.callbackUrl and oauth.callbackPort name different ports")
        ]
        for (settings, expected) in cases {
            #expect(error(["url": "https://a.example", "oauth": settings]) == "server \"s\": " + expected)
        }
        for url in ["https://localhost/callback", "http://example.com/callback", "http://localhost/callback?x=1"] {
            #expect(error(["url": "https://a.example", "oauth": ["callbackUrl": url]]).contains("oauth.callbackUrl must be an http URI"))
        }
        #expect(error(["url": "https://a.example", "oauth": ["callbackUrl": "http://[::1]:8080/cb", "callbackPort": 8080]]) == "")
        #expect(error(["url": "https://a.example", "oauth": ["clientRegistration": "dcr", "clientName": "app"]]) == "")
        #expect(error(["url": "https://a.example", "oauth": ["authServerMetadataUrl": "http://auth.example/.well-known/x"]]).contains("oauth.authServerMetadataUrl must be an https URL"))
    }

    @Test func cimdPassesCallbackAndReportsApplicationError() {
        var checked: [String?] = []
        let check: (String?) -> String? = { callback in
            checked.append(callback)
            return callback?.hasSuffix("/other") == true ? "the documents do not list it" : nil
        }
        let base: [String: Any] = ["url": "https://a.example", "oauth": ["clientRegistration": "cimd"]]
        _ = validateMcpServerConfig(name: "s", value: base, checkMetadataDocumentCallback: check)
        let other: [String: Any] = ["url": "https://a.example", "oauth": ["clientRegistration": "cimd", "callbackUrl": "http://localhost/other"]]
        if case .invalid(let message) = validateMcpServerConfig(name: "s", value: other, checkMetadataDocumentCallback: check) {
            #expect(message == "server \"s\": the documents do not list it")
        } else { Issue.record("Expected callback error") }
        #expect(checked == [nil, "http://localhost/other"])
        let conflict: [String: Any] = ["url": "https://a.example", "oauth": ["clientRegistration": "cimd", "clientId": "id"]]
        if case .invalid(let message) = validateMcpServerConfig(name: "s", value: conflict, checkMetadataDocumentCallback: check) {
            #expect(message == "server \"s\": oauth.clientRegistration \"cimd\" cannot be combined with oauth.clientId or oauth.clientName")
        } else { Issue.record("Expected registration conflict") }
    }

    @Test func outputWithinLimitDoesNotCallSaver() async {
        let input = String(repeating: "x", count: MCP_OUTPUT_MAX_BYTES)
        let limited = await limitMcpContent([
            .text(TextContent(text: input)), .image(ImageContent(data: "AAAA", mimeType: "image/png"))
        ], saveOutput: { _, _ in
            Issue.record("Saver must not run for content within the limit")
            return URL(fileURLWithPath: "/tmp/full.txt")
        })
        #expect(limited.content.count == 2)
        #expect(limited.fullOutputPath == nil)
        if case .text(let text) = limited.content[0] { #expect(text.text == input) }
        else { Issue.record("Expected text") }
        if case .image(let image) = limited.content[1] { #expect(image.data == "AAAA") }
        else { Issue.record("Expected image") }
    }

    @Test func outputJoinsTextAndKeepsImages() async {
        let full = (1...3000).map { "line \($0)" }.joined(separator: "\n")
        let split = full.index(full.startIndex, offsetBy: 103)
        let boundary = full[split...].firstIndex(of: "\n")!
        let image = ImageContent(data: "AAAA", mimeType: "image/png")
        let limited = await limitMcpContent([
            .text(TextContent(text: String(full[..<boundary]))), .image(image),
            .text(TextContent(text: String(full[full.index(after: boundary)...])))
        ], saveOutput: { data, suffix in
            #expect(String(decoding: data, as: UTF8.self) == full)
            #expect(suffix == ".txt")
            return URL(fileURLWithPath: "/tmp/full.txt")
        })
        #expect(limited.content.count == 2)
        if case .image(let kept) = limited.content[1] {
            #expect(kept.data == image.data)
            #expect(kept.mimeType == image.mimeType)
        } else { Issue.record("Expected image") }
        if case .text(let text) = limited.content[0] {
            #expect(text.text.hasPrefix("Warning: truncated output (original token count: \((full.utf8.count + 3) / 4))\nTotal output lines: 3000\n\nline 1\nline 2\n"))
            #expect(text.text.utf8.count < MCP_OUTPUT_MAX_BYTES + 1024)
        } else { Issue.record("Expected text") }
    }

    @Test func outputPreservesScalarCountAtBothCuts() async throws {
        let source = "a" + String(repeating: "é", count: 20_000) + "end"
        let limited = await limitMcpContent([.text(TextContent(text: source))])
        guard case .text(let block) = limited.content[0] else { Issue.record("Expected text"); return }
        let text = block.text
        let marker = try #require(text.range(of: "…[0-9]+ chars truncated…", options: .regularExpression))
        let start = try #require(text.range(of: "\n\n")?.upperBound)
        let head = text[start..<marker.lowerBound]
        let tail = text[marker.upperBound...]
        let removed = try #require(Int(text[marker].dropFirst().prefix(while: { $0.isNumber })))
        #expect(head.utf8.count <= MCP_OUTPUT_MAX_BYTES / 2)
        #expect(tail.utf8.count <= MCP_OUTPUT_MAX_BYTES / 2)
        #expect(head.unicodeScalars.count + tail.unicodeScalars.count + removed == source.unicodeScalars.count)
    }
}
