import Foundation
import Testing
import TestEnvironmentSupport
import PiSwiftAI
import PiSwiftCodingAgent

// Upstream 8c4e87389, tools.test.ts:912: ambient rg config must not change grep.
@Test(.processEnvironment, .timeLimit(.minutes(1)))
func v140GrepIgnoresRipgrepConfig() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pi-grep-config-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let config = root.appendingPathComponent("rg-config")
    let fixture = root.appendingPathComponent("fixture.txt")
    try "--fixed-strings\n".write(to: config, atomically: true, encoding: .utf8)
    try "aXb\na.b\n".write(to: fixture, atomically: true, encoding: .utf8)
    let previous = ProcessInfo.processInfo.environment["RIPGREP_CONFIG_PATH"]
    setenv("RIPGREP_CONFIG_PATH", config.path, 1)
    defer {
        if let previous { setenv("RIPGREP_CONFIG_PATH", previous, 1) }
        else { unsetenv("RIPGREP_CONFIG_PATH") }
    }
    let result = try await createGrepTool(cwd: root.path).execute("rg-config", [
        "pattern": AnyCodable("a.b"), "path": AnyCodable(fixture.path), "literal": AnyCodable(false),
    ], nil, nil)
    let output = result.content.compactMap { block -> String? in
        if case .text(let text) = block { return text.text }
        return nil
    }.joined(separator: "\n")
    #expect(output.contains("fixture.txt:1: aXb"))
    #expect(output.contains("fixture.txt:2: a.b"))
}
