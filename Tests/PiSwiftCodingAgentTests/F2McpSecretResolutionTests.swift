import Foundation
import PiSwiftMCP
import Testing
@testable import PiSwiftCodingAgent

private func f2SecretConnection(_ secret: String) -> McpServerConnection {
    McpServerConnection(entry: McpServerEntry(name: "secret", config: .init(
        url: "https://example.invalid/mcp", oauth: McpOAuthConfig(clientSecret: secret)),
        source: "fixture", scope: .global), cwd: FileManager.default.temporaryDirectory,
        credentials: McpOAuthCredentialStore(backend: InMemoryAuthStorageBackend()))
}

private func f2SecretDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pi-f2-secret-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func f2SecretQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

#if !canImport(UIKit)
// Port resolve-config-value.test.ts command cases through the MCP OAuth API.
@Test(arguments: [
    ("!echo '  spaced-key  '", "spaced-key"),
    ("!printf 'line1\\nline2'", "line1\nline2"),
    ("!echo 'hello world' | tr ' ' '-'", "hello-world"),
    ("!printf '\u{FEFF}value\u{FEFF}'", "value"),
])
func f2McpOAuthCommandsTrimUpstreamWhitespace(_ command: String, _ expected: String) throws {
    #expect(try f2SecretConnection(command).oauthSettings().clientSecret == expected)
}

@Test(arguments: ["!exit 1", "!nonexistent-command-12345", "!printf ''",
                  "!printf 'value'; exit 1", "!printf ' \\n\\t'",
                  "!head -c 1048577 /dev/zero | tr '\\000' 'a'"])
func f2McpOAuthFailedCommandsUseUpstreamError(_ command: String) throws {
    do {
        _ = try f2SecretConnection(command).oauthSettings()
        Issue.record("Command resolution must fail")
    } catch McpRuntimeError.invalidConfig(let message) {
        #expect(message == "Failed to resolve MCP server \"secret\" oauth.clientSecret from shell command: \(command.dropFirst())")
    }
}

@Test(arguments: [65536, 1048576])
func f2McpOAuthCommandDrainsOutputWithinUpstreamBufferLimit(_ count: Int) throws {
    let command = "!head -c \(count) /dev/zero | tr '\\000' 'a'"
    #expect(try f2SecretConnection(command).oauthSettings().clientSecret == String(repeating: "a", count: count))
}

// Port the resolveConfigValueUncached per-call case, and check a changed secret.
@Test func f2McpOAuthCommandReadsCurrentSecretOnEveryCall() throws {
    let root = try f2SecretDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("secret")
    let connection = f2SecretConnection("!cat \(f2SecretQuote(path.path))")
    try "first".write(to: path, atomically: true, encoding: .utf8)
    #expect(try connection.oauthSettings().clientSecret == "first")
    try "second".write(to: path, atomically: true, encoding: .utf8)
    #expect(try connection.oauthSettings().clientSecret == "second")
}

// runtime.ts uses resolveHeadersOrThrow and resolveConfigValueOrThrow for these paths too.
@Test(.timeLimit(.minutes(1)), arguments: [true, false])
func f2McpTransportCommandsRunOnEveryCall(_ http: Bool) async throws {
    let root = try f2SecretDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let counter = root.appendingPathComponent("counter")
    let command = "!printf 'run\\n' >> \(f2SecretQuote(counter.path)); printf value"
    let config = http ? McpServerConfig(url: "https://example.invalid/mcp", headers: ["X-Secret": command])
        : McpServerConfig(command: "fixture", env: ["SECRET": command])
    let entry = McpServerEntry(name: "secret", config: config, source: "fixture", scope: .global)
    for _ in 0..<2 {
        let transport = try createDefaultMcpTransport(entry: entry, cwd: root, authProvider: nil)
        await transport.close()
    }
    #expect(try String(contentsOf: counter, encoding: .utf8) == "run\nrun\n")
}
#endif

@Test(arguments: [
    ("${PI_SWIFT_F2_MISSING_A}", "environment variable: PI_SWIFT_F2_MISSING_A"),
    ("$PI_SWIFT_F2_MISSING_B/${PI_SWIFT_F2_MISSING_A}/$PI_SWIFT_F2_MISSING_B",
     "environment variables: PI_SWIFT_F2_MISSING_B, PI_SWIFT_F2_MISSING_A"),
])
func f2McpOAuthMissingVariablesUseUniqueReferenceOrder(_ value: String, _ detail: String) throws {
    #expect(ProcessInfo.processInfo.environment["PI_SWIFT_F2_MISSING_A"] == nil)
    #expect(ProcessInfo.processInfo.environment["PI_SWIFT_F2_MISSING_B"] == nil)
    do {
        _ = try f2SecretConnection(value).oauthSettings()
        Issue.record("Missing variables must fail")
    } catch McpRuntimeError.invalidConfig(let message) {
        #expect(message == "Failed to resolve MCP server \"secret\" oauth.clientSecret from \(detail)")
    }
}

// Port literal/template/escape cases without changing the process environment.
@Test(arguments: ["literal-key", "HOME", "", "${INVALID-NAME}", "${HOME", "$", "$$HOME", "$!literal"])
func f2McpOAuthLiteralAndEscapedTemplates(_ value: String) throws {
    let expected: String
    switch value {
    case "$$HOME": expected = "$HOME"
    case "$!literal": expected = "!literal"
    default: expected = value
    }
    #expect(try f2SecretConnection(value).oauthSettings().clientSecret == expected)
}

#if os(iOS)
private let f2SecretTransportKinds = [true]
#else
private let f2SecretTransportKinds = [true, false]
#endif

@Test(arguments: f2SecretTransportKinds)
func f2McpTransportMissingVariablesUseUpstreamContext(_ http: Bool) throws {
    let variable = "${PI_SWIFT_F2_MISSING_A}"
    let config = http ? McpServerConfig(url: "https://example.invalid/mcp", headers: ["X-Secret": variable])
        : McpServerConfig(command: "fixture", env: ["SECRET": variable])
    let entry = McpServerEntry(name: "secret", config: config, source: "fixture", scope: .global)
    do {
        _ = try createDefaultMcpTransport(entry: entry, cwd: FileManager.default.temporaryDirectory, authProvider: nil)
        Issue.record("Missing variables must fail")
    } catch McpRuntimeError.invalidConfig(let message) {
        let field = http ? "header \"X-Secret\"" : "env \"SECRET\""
        #expect(message == "Failed to resolve MCP server \"secret\" \(field) from environment variable: PI_SWIFT_F2_MISSING_A")
    }
}
