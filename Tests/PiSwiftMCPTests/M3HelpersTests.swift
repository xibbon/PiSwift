import Foundation
import PiSwiftAI
import PiSwiftMCP
import Testing

@Suite("v1.5.2 MCP shared helpers")
struct M3HelpersTests {
    private func error(_ result: McpServerConfigResult) -> String? {
        if case .invalid(let message) = result { return message }
        return nil
    }

    @Test("adds type object and empty properties when missing")
    func addsTypeObjectAndEmptyPropertiesWhenMissing() {
        let empty = normalizeMcpInputSchema([:])
        #expect(empty["type"] as? String == "object")
        #expect((empty["properties"] as? [String: Any])?.isEmpty == true)
        #expect(normalizeMcpInputSchema(["type": NSNull()])["type"] as? String == "object")
    }

    @Test("keeps the schema's own keywords")
    func keepsTheSchemasOwnKeywords() {
        let schema: [String: Any] = ["type": "object", "properties": ["query": ["type": "string"]],
                                     "required": ["query"], "additionalProperties": false]
        let result = normalizeMcpInputSchema(schema)
        #expect(result["required"] as? [String] == ["query"])
        #expect(result["additionalProperties"] as? Bool == false)
        #expect((result["properties"] as? [String: Any])?["query"] != nil)
    }

    @Test("returns content within the limit as it is, without saving")
    func returnsContentWithinTheLimitAsItIsWithoutSaving() async {
        let content: [ContentBlock] = [.text(TextContent(text: String(repeating: "x", count: MCP_OUTPUT_MAX_BYTES)))]
        let limited = await limitMcpContent(content)
        #expect(limited.fullOutputPath == nil)
        #expect(limited.content.count == 1)
        if case .text(let value) = limited.content[0] {
            #expect(value.text == String(repeating: "x", count: MCP_OUTPUT_MAX_BYTES))
        } else { Issue.record("Expected text") }
    }

    @Test("cuts the middle of longer text, saves the full text and keeps images")
    func cutsTheMiddleOfLongerTextSavesTheFullTextAndKeepsImages() async {
        let full = (1...3000).map { "line \($0)" }.joined(separator: "\n")
        let saver: McpOutputSaver = { data, fileExtension in
            #expect(String(decoding: data, as: UTF8.self) == full)
            #expect(fileExtension == ".txt")
            return URL(fileURLWithPath: "/tmp/full.txt")
        }
        let limited = await limitMcpContent([.text(TextContent(text: full))], saveOutput: saver)
        #expect(limited.fullOutputPath == "/tmp/full.txt")
        if case .text(let value) = limited.content[0] {
            #expect(value.text.contains("…"))
            #expect(value.text.hasSuffix("line 3000\n\n[Full output: /tmp/full.txt (read it with offset/limit)]"))
        } else { Issue.record("Expected text") }
    }

    @Test("reports a failed save, and names no file without a saver")
    func reportsAFailedSaveAndNamesNoFileWithoutASaver() async {
        let content: [ContentBlock] = [.text(TextContent(text: String(repeating: "y", count: MCP_OUTPUT_MAX_BYTES + 1)))]
        let failed = await limitMcpContent(content, saveOutput: { _, _ in throw TestError.diskFull })
        #expect(failed.fullOutputPath == nil)
        if case .text(let value) = failed.content[0] {
            #expect(value.text.hasSuffix("[Could not save the full output: disk full]"))
        }
        let unsaved = await limitMcpContent(content)
        #expect(unsaved.fullOutputPath == nil)
        if case .text(let value) = unsaved.content[0] { #expect(!value.text.contains("Full output:")) }
    }

    @Test("cuts multi-byte text only at character boundaries")
    func cutsMultiByteTextOnlyAtCharacterBoundaries() async {
        let input = "a" + String(repeating: "é", count: 20_000) + "end"
        let limited = await limitMcpContent([.text(TextContent(text: input))])
        if case .text(let value) = limited.content[0] {
            #expect(!value.text.contains("\u{fffd}"))
            #expect(value.text.hasSuffix("end"))
        } else { Issue.record("Expected text") }
    }

    @Test("accepts stdio and HTTP entries and keeps them as given")
    func acceptsStdioAndHTTPEntriesAndKeepsThemAsGiven() {
        let stdio: [String: Any] = ["command": "npx", "args": ["-y", "server"], "enabled": false]
        if case .stdio(let value) = validateMcpServerConfig(name: "files", value: stdio) {
            #expect(value.fields["command"] as? String == "npx")
        } else { Issue.record("Expected stdio") }
        let http: [String: Any] = ["url": "https://example.com/mcp", "timeout": 30, "description": "Docs"]
        if case .http(let value) = validateMcpServerConfig(name: "docs", value: http) {
            #expect(value.fields["description"] as? String == "Docs")
        } else { Issue.record("Expected HTTP") }
    }

    @Test("picks the transport from type, url and command")
    func picksTheTransportFromTypeURLAndCommand() {
        let both: [String: Any] = ["url": "https://a.example", "command": "x"]
        if case .http = validateMcpServerConfig(name: "s", value: both) {} else { Issue.record("Expected HTTP") }
        var typed = both; typed["type"] = "stdio"
        if case .stdio = validateMcpServerConfig(name: "s", value: typed) {} else { Issue.record("Expected stdio") }
        #expect(error(validateMcpServerConfig(name: "s", value: ["type": "sse", "url": "https://a.example/sse"])) ==
            "server \"s\": legacy SSE transport is not supported; use the streamable HTTP URL")
    }

    @Test("reports invalid names and fields")
    func reportsInvalidNamesAndFields() {
        #expect(error(validateMcpServerConfig(name: "bad name", value: ["command": "x"])) ==
            "invalid server name \"bad name\" (use letters, digits, \"_\" and \"-\")")
        #expect(error(validateMcpServerConfig(name: "s", value: ["command": "x", "enabled": "yes"])) ==
            "server \"s\": enabled must be a boolean")
        #expect(error(validateMcpServerConfig(name: "s", value: ["url": "file:///x"])) ==
            "server \"s\": url must be an http or https URL")
    }

    @Test("checks oauth settings")
    func checksOAuthSettings() {
        func oauth(_ fields: Any) -> String? {
            error(validateMcpServerConfig(name: "s", value: ["url": "https://a.example", "oauth": fields]))
        }
        #expect(oauth(["callbackPort": 70000]) == "server \"s\": oauth.callbackPort must be a port number")
        #expect(oauth(["clientName": " "]) == "server \"s\": oauth.clientName must be a non-empty string")
        #expect(oauth(["authServerMetadataUrl": "http://127.0.0.1/.well-known/x"]) == nil)
    }

    @Test("rejects auto client registration without per-server documents")
    func rejectsAutoClientRegistrationWithoutPerServerDocuments() {
        let entry: [String: Any] = ["url": "https://a.example", "oauth": ["clientRegistration": "auto"]]
        #expect(error(validateMcpServerConfig(name: "s", value: entry)) ==
            "server \"s\": oauth.clientRegistration must be \"dcr\" or \"cimd\"")
    }

    @Test("allows cimd only with the application's check of the callback")
    func allowsCimdOnlyWithTheApplicationsCheckOfTheCallback() {
        let entry: [String: Any] = ["url": "https://a.example", "oauth": ["clientRegistration": "cimd"]]
        #expect(error(validateMcpServerConfig(name: "s", value: entry)) ==
            "server \"s\": oauth.clientRegistration \"cimd\" is not supported: there are no Client ID Metadata Documents")
        if case .http = validateMcpServerConfig(name: "s", value: entry, checkMetadataDocumentCallback: { _ in nil }) {
        } else { Issue.record("Expected HTTP") }
    }

    @Test("keeps unknown fields for the caller, after the shared fields are valid")
    func keepsUnknownFieldsForTheCallerAfterTheSharedFieldsAreValid() {
        let entry: [String: Any] = ["command": "x", "shared": true, "runOn": "host"]
        if case .stdio(let value) = validateMcpServerConfig(name: "s", value: entry) {
            #expect(value.fields["shared"] as? Bool == true)
            #expect(value.fields["runOn"] as? String == "host")
        } else { Issue.record("Expected stdio") }
    }

    @Test("is true for entries without command, url or type")
    func isTrueForEntriesWithoutCommandURLOrType() {
        #expect(isMcpServerOverride(["enabled": false]))
        #expect(!isMcpServerOverride(["command": "x"]))
    }

    private enum TestError: Error, LocalizedError {
        case diskFull
        var errorDescription: String? { "disk full" }
    }
}
