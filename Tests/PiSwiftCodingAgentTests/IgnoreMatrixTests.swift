import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

private struct IgnoreMatrixFixture: Decodable, Sendable {
    let schemaVersion: Int
    let versions: Versions
    let cases: [Case]

    struct Versions: Decodable, Sendable {
        let rg: String
        let fd: String?
    }

    struct Case: Decodable, Sendable {
        let name: String
        let gitRepository: Bool
        let searchPath: String
        let directories: [String]
        let symlinks: [String: String]
        let files: [String: String]
        let grepGlob: String?
        let findPattern: String
        let globalConfig: String
        let fileSearch: Bool
        let grep: Oracle
        let find: Oracle?
    }

    struct Oracle: Decodable, Sendable {
        let args: [String]
        let paths: [String]?
    }
}

private func ignoreMatrixText(_ result: AgentToolResult) -> String {
    result.content.compactMap {
        if case .text(let text) = $0 { return text.text }
        return nil
    }.joined(separator: "\n")
}

private func ignoreMatrixGrepPaths(_ output: String) -> Set<String> {
    if output == "No matches found" { return [] }
    return Set(output.split(separator: "\n").compactMap { line in
        line.range(of: ":1: ").map { String(line[..<$0.lowerBound]) }
    })
}

private func ignoreMatrixFindPaths(_ output: String) -> Set<String> {
    if output == "No files found matching pattern" { return [] }
    return Set(output.split(separator: "\n").map(String.init))
}

private func ignoreMatrixRun(_ fixture: IgnoreMatrixFixture.Case) async throws -> (Set<String>, Set<String>) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pi-ignore-matrix-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    if fixture.gitRepository {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: false)
    }
    for relative in fixture.directories {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(relative), withIntermediateDirectories: true)
    }
    for (relative, content) in fixture.files {
        let file = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.replacingOccurrences(of: "<ROOT>", with: root.path).write(to: file, atomically: true, encoding: .utf8)
    }
    for (relative, target) in fixture.symlinks {
        let link = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target)
    }
    let home = root.appendingPathComponent("home")
    let xdg = root.appendingPathComponent("xdg")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: xdg, withIntermediateDirectories: true)
    let environment = [
        "HOME": home.path,
        "XDG_CONFIG_HOME": xdg.path,
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": fixture.globalConfig == "core" ? home.appendingPathComponent(".gitconfig").path : root.appendingPathComponent("absent-global-config").path,
        "GIT_CONFIG_SYSTEM": root.appendingPathComponent("absent-system-config").path,
        "RIPGREP_CONFIG_PATH": root.appendingPathComponent("absent-rg-config").path,
    ]
    let path = fixture.searchPath
    var grepParameters = ["pattern": AnyCodable("needle"), "path": AnyCodable(path)]
    if let glob = fixture.grepGlob { grepParameters["glob"] = AnyCodable(glob) }
    let grepResult = try await createGrepTool(cwd: root.path, options: GrepToolOptions(environment: environment))
        .execute("ignore-matrix-grep", grepParameters, nil, nil)
    var findPaths: Set<String> = []
    if !fixture.fileSearch {
        let findResult = try await createFindTool(cwd: root.path, environment: environment)
            .execute("ignore-matrix-find", ["pattern": AnyCodable(fixture.findPattern), "path": AnyCodable(path)], nil, nil)
        findPaths = ignoreMatrixFindPaths(ignoreMatrixText(findResult))
    }
    return (ignoreMatrixGrepPaths(ignoreMatrixText(grepResult)), findPaths)
}

@Test("native grep and find match pinned external ignore fixtures", .timeLimit(.minutes(2)))
func nativeIgnoreMatrix() async throws {
    let url = try #require(Bundle.module.url(forResource: "ignore-matrix", withExtension: "json", subdirectory: "fixtures"))
    let matrix = try JSONDecoder().decode(IgnoreMatrixFixture.self, from: Data(contentsOf: url))
    #expect(matrix.schemaVersion == 2)
    #expect(matrix.versions.rg == "ripgrep 15.2.0")
    #expect(matrix.cases.count >= 40)
    for fixture in matrix.cases {
        let (grep, find) = try await ignoreMatrixRun(fixture)
        #expect(grep == Set(fixture.grep.paths ?? []), "rg case: \(fixture.name), args: \(fixture.grep.args)")
        if let oracle = fixture.find, let expectedFind = oracle.paths {
            #expect(find == Set(expectedFind), "fd case: \(fixture.name), args: \(oracle.args)")
        }
    }
}
