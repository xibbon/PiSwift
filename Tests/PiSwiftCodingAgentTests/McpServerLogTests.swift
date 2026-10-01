import Foundation
import Testing
import PiSwiftAI
@testable import PiSwiftCodingAgent

@Test func mcpLogFormatsServerMessages() {
    let date = Date(timeIntervalSince1970: 0)
    let params = AnyCodable(["level": "warning", "logger": "sync", "data": "first\nsecond"])
    #expect(formatMcpLogMessage(server: "docs", params: params, now: date) ==
        "1970-01-01T00:00:00.000Z [docs] warning sync: first\n    second\n")
    #expect(formatMcpLogMessage(server: "docs", params: AnyCodable(["data": ["ready": true]]), now: date) ==
        "1970-01-01T00:00:00.000Z [docs] info {\"ready\":true}\n")
}

@Test(.timeLimit(.minutes(1))) func mcpLogRotatesAfterFiveMiB() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent("mcp.log")
    try Data(repeating: 65, count: McpServerLog.maxBytes + 1).write(to: path)
    let log = McpServerLog(path: path)
    await log.write(server: "docs", params: AnyCodable(["data": "next"]))
    #expect(FileManager.default.fileExists(atPath: path.path + ".1"))
    let rotated = try Data(contentsOf: URL(fileURLWithPath: path.path + ".1"))
    #expect(rotated.count == McpServerLog.maxBytes + 1)
    let current = try String(contentsOf: path, encoding: .utf8)
    #expect(current.contains("[docs] info next"))
}
