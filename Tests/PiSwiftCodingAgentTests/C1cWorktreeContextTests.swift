import Foundation
import Testing
import PiSwiftCodingAgent

private struct C1cWorktreeFixture {
    let root: URL
    let main: URL
    let worktree: URL
    let source: URL
    let agent: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("c1c-worktree-\(UUID().uuidString)")
        main = root.appendingPathComponent("outer/main")
        worktree = main.appendingPathComponent("worktrees/feat")
        source = worktree.appendingPathComponent("src")
        agent = root.appendingPathComponent("agent")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
        let git = main.appendingPathComponent(".git/worktrees/feat")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(to: main.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        try "ref: refs/heads/feat\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try "../..".write(to: git.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
        try "gitdir: \(git.path)\n".write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
    }

    func load() -> [ContextFile] {
        loadProjectContextFiles(LoadContextFilesOptions(cwd: source.path, agentDir: agent.path))
    }
}

// resource-loader.test.ts:1247,1258
@Test(arguments: [false, true]) func c1cNestedWorktreeKeepsLexicalContextPath(_ sharedTarget: Bool) throws {
    let fixture = try C1cWorktreeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let mainFile = fixture.main.appendingPathComponent("AGENTS.md")
    let worktreeFile = fixture.worktree.appendingPathComponent("AGENTS.md")
    let content = sharedTarget ? "shared instructions" : "main repo instructions"
    if sharedTarget {
        let shared = fixture.root.appendingPathComponent("outer/shared-agents.md")
        try content.write(to: shared, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: mainFile, withDestinationURL: shared)
        try FileManager.default.createSymbolicLink(at: worktreeFile, withDestinationURL: shared)
    } else {
        try content.write(to: mainFile, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: worktreeFile, withDestinationURL: mainFile)
    }
    let files = fixture.load()
    #expect(files.map(\.path) == [worktreeFile.path])
    #expect(files.map(\.content) == [content])
}

@Test func c1cNestedWorktreeInheritsMainContextWithoutItsOwnFile() throws {
    let fixture = try C1cWorktreeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let mainFile = fixture.main.appendingPathComponent("AGENTS.md")
    try "main repo instructions".write(to: mainFile, atomically: true, encoding: .utf8)
    let files = fixture.load()
    #expect(files.map(\.path) == [mainFile.path])
    #expect(files.map(\.content) == ["main repo instructions"])
}
