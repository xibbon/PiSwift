import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

private func c1ExpectPrivateOutput(_ path: String, prefix: String, extension fileExtension: String) throws {
    let url = URL(fileURLWithPath: path)
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
    #expect(permissions.intValue & 0o777 == 0o600)
    #expect(url.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL)
    let escapedExtension = NSRegularExpression.escapedPattern(for: fileExtension)
    #expect(url.lastPathComponent.range(of: "^\(prefix)-[0-9a-f]{16}\(escapedExtension)$", options: .regularExpression) != nil)
}

// Upstream v1.0.3 output-files.ts creates private whole-file and streamed output.
@Test func c1OutputFilesWholeAndStream() throws {
    let bytes = Data([0, 1, 2, 0xff])
    let path = try writeOutputFile(prefix: "pi-c1", extension: ".bin", data: bytes)
    defer { try? FileManager.default.removeItem(atPath: path) }
    try c1ExpectPrivateOutput(path, prefix: "pi-c1", extension: ".bin")
    #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == bytes)

    let file = try createOutputFileStream(prefix: "pi-c1", extension: ".log")
    defer {
        try? file.stream.close()
        try? FileManager.default.removeItem(atPath: file.path)
    }
    try c1ExpectPrivateOutput(file.path, prefix: "pi-c1", extension: ".log")
    try file.stream.write(contentsOf: bytes.prefix(2))
    try file.stream.write(contentsOf: bytes.suffix(2))
    try file.stream.close()
    try c1ExpectPrivateOutput(file.path, prefix: "pi-c1", extension: ".log")
    #expect(try Data(contentsOf: URL(fileURLWithPath: file.path)) == bytes)
    #expect(file.path != path)
}

// Upstream's wx rejects both an existing file and a symbolic link.
@Test(arguments: [false, true]) func c1OutputFilesExclusiveCreateRejectsExistingPath(link: Bool) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-c1-fixture-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("target")
    let bytes = Data("keep this data".utf8)
    try bytes.write(to: target)
    let path = link ? directory.appendingPathComponent("link") : target
    if link { try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target) }
    #expect(throws: POSIXError.self) { try createOutputFileStream(at: path.path) }
    #expect(try Data(contentsOf: target) == bytes)
    if link {
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: path.path) == target.path)
    }
}

private struct C1OutputBashOperations: BashOperations {
    let chunks: [String]

    func execute(_ command: String, options: BashExecutorOptions?) async throws -> BashResult {
        for chunk in chunks { options?.onChunk?(chunk) }
        return BashResult(output: chunks.joined(), exitCode: 0, cancelled: false, truncated: false)
    }
}

// Swift's streaming spill and final line-truncation fallback map to OutputAccumulator.
@Test(arguments: [false, true]) func c1OutputFilesBashToolPaths(streamed: Bool) async throws {
    let chunks = streamed
        ? [String(repeating: "a", count: DEFAULT_MAX_BYTES + 1), "\ntail", "\nend"]
        : [String(repeating: "line\n", count: DEFAULT_MAX_LINES + 1)]
    let tool = createBashTool(cwd: FileManager.default.currentDirectoryPath,
                              options: BashToolOptions(operations: C1OutputBashOperations(chunks: chunks)))
    let result = try await tool.execute("c1", ["command": AnyCodable("unused")], nil, nil)
    let fields = try #require(result.details?.value as? [String: Any])
    let path = try #require(fields["fullOutputPath"] as? String)
    defer { try? FileManager.default.removeItem(atPath: path) }
    try c1ExpectPrivateOutput(path, prefix: "pi-bash", extension: ".log")
    #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data(chunks.joined().utf8))
}

// The structured-output fallback is a separate Swift writer from the accumulator.
@Test func c1OutputFilesBashStructuredFallback() throws {
    let directory = FileManager.default.temporaryDirectory
    let previous = Set(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))
    let output = UUID().uuidString + String(repeating: "x", count: 1_048_577)
    let expected = Data(output.utf8)
    let result = try structuredBashOutput(output, tempFilePath: nil)
    let paths = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { !previous.contains($0) && $0.lastPathComponent.hasPrefix("pi-bash-") }
        .filter { (try? Data(contentsOf: $0)) == expected }
    defer { for path in paths { try? FileManager.default.removeItem(at: path) } }
    #expect(result.truncated)
    #expect(paths.count == 1)
    let path = try #require(paths.first)
    try c1ExpectPrivateOutput(path.path, prefix: "pi-bash", extension: ".log")
    #expect(try Data(contentsOf: path) == expected)
}

#if !canImport(UIKit)
// Swift's process executor uses the same helper as upstream's executor spill.
@Test func c1OutputFilesBashExecutorPath() async throws {
    let size = DEFAULT_MAX_BYTES + 1
    let result = try await executeBash("printf '%\(size)s' x")
    let path = try #require(result.fullOutputPath)
    defer { try? FileManager.default.removeItem(atPath: path) }
    #expect(result.truncated)
    try c1ExpectPrivateOutput(path, prefix: "pi-bash", extension: ".log")
    #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data((String(repeating: " ", count: size - 1) + "x").utf8))
}
#endif

// Upstream v1.0.3 MCP output covers text spills and binary resource extensions.
@Test(arguments: [".txt", ".bin", ".pdf"]) func c1OutputFilesMcpPath(fileExtension: String) async throws {
    let bytes = Data([0, 0xff, 1, 2])
    let url = try await saveMcpOutput(bytes, extension: fileExtension)
    defer { try? FileManager.default.removeItem(at: url) }
    try c1ExpectPrivateOutput(url.path, prefix: "pi-mcp", extension: fileExtension)
    #expect(try Data(contentsOf: url) == bytes)
}
