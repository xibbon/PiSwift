import Foundation
import Testing
import PiSwiftAI
@testable import PiSwiftCodingAgent
#if canImport(CryptoKit)
import CryptoKit
#endif

// MARK: - Git update tests

/// Tests for git-based extension updates, specifically handling force-push scenarios.
///
/// These tests verify that DefaultPackageManager.update() handles:
/// - Normal git updates (no force-push)
/// - Force-pushed remotes gracefully
/// - Pinned sources (shouldn't update)

// MARK: - Test helpers

private func git(_ args: [String], cwd: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = args
    process.currentDirectoryURL = URL(fileURLWithPath: cwd)

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe

    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)

    if process.terminationStatus != 0 {
        throw GitTestError.commandFailed("git \(args.joined(separator: " ")): \(output)")
    }

    return output
}

private func createCommit(repoDir: String, filename: String, content: String, message: String) throws -> String {
    let filePath = URL(fileURLWithPath: repoDir).appendingPathComponent(filename).path
    try content.write(toFile: filePath, atomically: true, encoding: .utf8)
    _ = try git(["add", filename], cwd: repoDir)
    _ = try git(["commit", "-m", message], cwd: repoDir)
    return try git(["rev-parse", "HEAD"], cwd: repoDir)
}

private func getCurrentCommit(repoDir: String) throws -> String {
    try git(["rev-parse", "HEAD"], cwd: repoDir)
}

private func getFileContent(repoDir: String, filename: String) throws -> String {
    let filePath = URL(fileURLWithPath: repoDir).appendingPathComponent(filename).path
    return try String(contentsOfFile: filePath, encoding: .utf8)
}

private enum GitTestError: Error {
    case commandFailed(String)
}

private final class CommandCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [String] = []

    func append(_ command: String) {
        lock.lock()
        commands.append(command)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return commands
    }
}

// MARK: - Test fixture

private final class GitUpdateTestFixture {
    let tempDir: String
    let remoteDir: String
    let agentDir: String
    let installedDir: String
    let settingsManager: SettingsManager
    let packageManager: DefaultPackageManager
    let gitSource = "git:github.com/test/extension"

    init() throws {
        let uuid = UUID().uuidString
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("git-update-test-\(uuid)")
            .path

        remoteDir = URL(fileURLWithPath: tempDir).appendingPathComponent("remote").path
        agentDir = URL(fileURLWithPath: tempDir).appendingPathComponent("agent").path

        // This matches the path structure: agentDir/git/<host>/<path>
        installedDir = URL(fileURLWithPath: agentDir)
            .appendingPathComponent("git")
            .appendingPathComponent("github.com")
            .appendingPathComponent("test")
            .appendingPathComponent("extension")
            .path

        try FileManager.default.createDirectory(atPath: agentDir, withIntermediateDirectories: true)

        settingsManager = SettingsManager.inMemory()
        packageManager = DefaultPackageManager(cwd: tempDir, agentDir: agentDir, settingsManager: settingsManager)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: tempDir)
    }

    /// Sets up a "remote" repository and clones it to the installed directory.
    /// This simulates what packageManager.install() would do.
    func setupRemoteAndInstall() throws {
        // Create "remote" repository
        try FileManager.default.createDirectory(atPath: remoteDir, withIntermediateDirectories: true)
        _ = try git(["init"], cwd: remoteDir)
        _ = try git(["config", "user.email", "test@test.com"], cwd: remoteDir)
        _ = try git(["config", "user.name", "Test"], cwd: remoteDir)
        _ = try createCommit(repoDir: remoteDir, filename: "extension.ts", content: "// v1", message: "Initial commit")

        // Clone to installed directory (simulating what install() does)
        let parentDir = URL(fileURLWithPath: installedDir).deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
        _ = try git(["clone", remoteDir, installedDir], cwd: tempDir)
        _ = try git(["config", "user.email", "test@test.com"], cwd: installedDir)
        _ = try git(["config", "user.name", "Test"], cwd: installedDir)

        // Add to settings so update() processes this source
        settingsManager.setPackages([.simple(gitSource)])
    }
}

// MARK: - Normal update tests

@Test func gitUpdateToLatestCommitWhenRemoteHasNewCommits() async throws {
    let fixture = try GitUpdateTestFixture()
    try fixture.setupRemoteAndInstall()

    #expect(try getFileContent(repoDir: fixture.installedDir, filename: "extension.ts") == "// v1")

    // Add a new commit to remote
    let newCommit = try createCommit(
        repoDir: fixture.remoteDir,
        filename: "extension.ts",
        content: "// v2",
        message: "Second commit"
    )

    // Update via package manager
    try await fixture.packageManager.update(nil)

    // Verify update succeeded
    #expect(try getCurrentCommit(repoDir: fixture.installedDir) == newCommit)
    #expect(try getFileContent(repoDir: fixture.installedDir, filename: "extension.ts") == "// v2")
}

@Test func gitUpdateHandlesMultipleCommitsAhead() async throws {
    let fixture = try GitUpdateTestFixture()
    try fixture.setupRemoteAndInstall()

    // Add multiple commits to remote
    _ = try createCommit(repoDir: fixture.remoteDir, filename: "extension.ts", content: "// v2", message: "Second commit")
    _ = try createCommit(repoDir: fixture.remoteDir, filename: "extension.ts", content: "// v3", message: "Third commit")
    let latestCommit = try createCommit(repoDir: fixture.remoteDir, filename: "extension.ts", content: "// v4", message: "Fourth commit")

    try await fixture.packageManager.update(nil)

    #expect(try getCurrentCommit(repoDir: fixture.installedDir) == latestCommit)
    #expect(try getFileContent(repoDir: fixture.installedDir, filename: "extension.ts") == "// v4")
}

@Test func gitUpdateHandlesDetachedHeadWithoutUpstream() async throws {
    let fixture = try GitUpdateTestFixture()
    try fixture.setupRemoteAndInstall()

    _ = try createCommit(repoDir: fixture.remoteDir, filename: "extension.ts", content: "// v2", message: "Second commit")
    let latestCommit = try createCommit(repoDir: fixture.remoteDir, filename: "extension.ts", content: "// v3", message: "Third commit")

    let detachedCommit = try getCurrentCommit(repoDir: fixture.installedDir)
    _ = try git(["checkout", detachedCommit], cwd: fixture.installedDir)

    try await fixture.packageManager.update(nil)

    #expect(try getCurrentCommit(repoDir: fixture.installedDir) == latestCommit)
    #expect(try getFileContent(repoDir: fixture.installedDir, filename: "extension.ts") == "// v3")
}

// MARK: - Force-push scenario tests

@Test func gitUpdateRecoversWhenRemoteHistoryIsRewritten() async throws {
    let fixture = try GitUpdateTestFixture()
    try fixture.setupRemoteAndInstall()
    let initialCommit = try getCurrentCommit(repoDir: fixture.remoteDir)

    // Add commit to remote
    _ = try createCommit(repoDir: fixture.remoteDir, filename: "extension.ts", content: "// v2", message: "Commit to keep")

    // Update to get the new commit
    try await fixture.packageManager.update(nil)
    #expect(try getFileContent(repoDir: fixture.installedDir, filename: "extension.ts") == "// v2")

    // Now force-push to rewrite history on remote
    _ = try git(["reset", "--hard", initialCommit], cwd: fixture.remoteDir)
    let rewrittenCommit = try createCommit(
        repoDir: fixture.remoteDir,
        filename: "extension.ts",
        content: "// v2-rewritten",
        message: "Rewritten commit"
    )

    // Update should succeed despite force-push
    try await fixture.packageManager.update(nil)

    #expect(try getCurrentCommit(repoDir: fixture.installedDir) == rewrittenCommit)
    #expect(try getFileContent(repoDir: fixture.installedDir, filename: "extension.ts") == "// v2-rewritten")
}

@Test func gitUpdateRecoversWhenLocalCommitNoLongerExistsInRemote() async throws {
    let fixture = try GitUpdateTestFixture()
    try fixture.setupRemoteAndInstall()

    // Add commits to remote
    _ = try createCommit(repoDir: fixture.remoteDir, filename: "extension.ts", content: "// v2", message: "Commit A")
    _ = try createCommit(repoDir: fixture.remoteDir, filename: "extension.ts", content: "// v3", message: "Commit B")

    // Update to get all commits
    try await fixture.packageManager.update(nil)
    #expect(try getFileContent(repoDir: fixture.installedDir, filename: "extension.ts") == "// v3")

    // Force-push remote to remove commits A and B
    _ = try git(["reset", "--hard", "HEAD~2"], cwd: fixture.remoteDir)
    let newCommit = try createCommit(
        repoDir: fixture.remoteDir,
        filename: "extension.ts",
        content: "// v2-new",
        message: "New commit replacing A and B"
    )

    // Update should succeed - the commits we had locally no longer exist
    try await fixture.packageManager.update(nil)

    #expect(try getCurrentCommit(repoDir: fixture.installedDir) == newCommit)
    #expect(try getFileContent(repoDir: fixture.installedDir, filename: "extension.ts") == "// v2-new")
}

@Test func gitUpdateHandlesCompleteHistoryRewrite() async throws {
    let fixture = try GitUpdateTestFixture()
    try fixture.setupRemoteAndInstall()

    // Remote gets several commits
    _ = try createCommit(repoDir: fixture.remoteDir, filename: "extension.ts", content: "// v2", message: "v2")
    _ = try createCommit(repoDir: fixture.remoteDir, filename: "extension.ts", content: "// v3", message: "v3")

    try await fixture.packageManager.update(nil)
    #expect(try getFileContent(repoDir: fixture.installedDir, filename: "extension.ts") == "// v3")

    // Maintainer force-pushes completely different history
    _ = try git(["reset", "--hard", "HEAD~2"], cwd: fixture.remoteDir)
    _ = try createCommit(repoDir: fixture.remoteDir, filename: "extension.ts", content: "// rewrite-a", message: "Rewrite A")
    let finalCommit = try createCommit(repoDir: fixture.remoteDir, filename: "extension.ts", content: "// rewrite-b", message: "Rewrite B")

    // Should handle this gracefully
    try await fixture.packageManager.update(nil)

    #expect(try getCurrentCommit(repoDir: fixture.installedDir) == finalCommit)
    #expect(try getFileContent(repoDir: fixture.installedDir, filename: "extension.ts") == "// rewrite-b")
}

// MARK: - Pinned source tests

@Test func gitUpdateSkipsPinnedSources() async throws {
    let fixture = try GitUpdateTestFixture()
    try fixture.setupRemoteAndInstall()
    let initialCommit = try getCurrentCommit(repoDir: fixture.installedDir)

    // Reconfigure with pinned ref
    fixture.settingsManager.setPackages([.simple("\(fixture.gitSource)@\(initialCommit)")])

    // Add new commit to remote
    _ = try createCommit(repoDir: fixture.remoteDir, filename: "extension.ts", content: "// v2", message: "Second commit")

    // Update should be skipped for pinned sources
    try await fixture.packageManager.update(nil)

    // Should still be on initial commit
    #expect(try getCurrentCommit(repoDir: fixture.installedDir) == initialCommit)
    #expect(try getFileContent(repoDir: fixture.installedDir, filename: "extension.ts") == "// v1")
}

@Test func temporaryGitSourcesAreRefreshedOnResolve() async throws {
    #if canImport(CryptoKit)
    let fixture = try GitUpdateTestFixture()
    let gitHost = "github.com"
    let gitPath = "test/extension-refresh"
    let gitSource = "git:\(gitHost)/\(gitPath)"
    let hash = SHA256.hash(data: Data("git-\(gitHost)-\(gitPath)".utf8))
        .map { String(format: "%02x", $0) }
        .joined()
    let cachedDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pi-extensions")
        .appendingPathComponent("git-\(gitHost)")
        .appendingPathComponent(String(hash.prefix(8)))
        .appendingPathComponent(gitPath).path

    try? FileManager.default.removeItem(atPath: cachedDir)
    try FileManager.default.createDirectory(
        at: URL(fileURLWithPath: cachedDir).appendingPathComponent("pi-extensions"),
        withIntermediateDirectories: true
    )
    let manifest = """
    {
      "pi": {
        "extensions": ["./pi-extensions"]
      }
    }
    """
    try manifest.write(
        toFile: URL(fileURLWithPath: cachedDir).appendingPathComponent("package.json").path,
        atomically: true,
        encoding: .utf8
    )
    let extensionPath = URL(fileURLWithPath: cachedDir)
        .appendingPathComponent("pi-extensions")
        .appendingPathComponent("session-breakdown.ts").path
    try "// stale".write(toFile: extensionPath, atomically: true, encoding: .utf8)

    let collector = CommandCollector()
    fixture.packageManager.setCommandRunnerForTests { command, args, _ in
        collector.append("\(command) \(args.joined(separator: " "))")
        if command == "git", args.first == "reset" {
            try "// fresh".write(toFile: extensionPath, atomically: true, encoding: .utf8)
        }
        return ExecResult(stdout: "", stderr: "", code: 0, killed: false)
    }

    _ = try await fixture.packageManager.resolveExtensionSources([gitSource], options: PackageResolveOptions(temporary: true))
    #expect(collector.snapshot().contains("git fetch --prune origin"))
    #expect(try getFileContent(repoDir: cachedDir, filename: "pi-extensions/session-breakdown.ts") == "// fresh")
    #else
    Issue.record("CryptoKit unavailable")
    #endif
}

@Test func temporaryBranchGitSourcesAreRefreshed() async throws {
    #if canImport(CryptoKit)
    let fixture = try GitUpdateTestFixture()
    let gitHost = "github.com"
    let gitPath = "test/extension-pinned"
    let gitSource = "git:\(gitHost)/\(gitPath)"
    // C43: a pinned ref is part of the temporary checkout identity.
    let hash = SHA256.hash(data: Data("git-\(gitHost)-\(gitPath)@main".utf8))
        .map { String(format: "%02x", $0) }
        .joined()
    let cachedDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pi-extensions")
        .appendingPathComponent("git-\(gitHost)")
        .appendingPathComponent(String(hash.prefix(8)))
        .appendingPathComponent(gitPath).path

    try? FileManager.default.removeItem(atPath: cachedDir)
    try FileManager.default.createDirectory(
        at: URL(fileURLWithPath: cachedDir).appendingPathComponent("pi-extensions"),
        withIntermediateDirectories: true
    )
    let manifest = """
    {
      "pi": {
        "extensions": ["./pi-extensions"]
      }
    }
    """
    try manifest.write(
        toFile: URL(fileURLWithPath: cachedDir).appendingPathComponent("package.json").path,
        atomically: true,
        encoding: .utf8
    )
    let extensionPath = URL(fileURLWithPath: cachedDir)
        .appendingPathComponent("pi-extensions")
        .appendingPathComponent("session-breakdown.ts").path
    try "// pinned".write(toFile: extensionPath, atomically: true, encoding: .utf8)

    let collector = CommandCollector()
    fixture.packageManager.setCommandRunnerForTests { command, args, _ in
        collector.append("\(command) \(args.joined(separator: " "))")
        return ExecResult(stdout: "", stderr: "", code: 0, killed: false)
    }

    _ = try await fixture.packageManager.resolveExtensionSources(["\(gitSource)@main"], options: PackageResolveOptions(temporary: true))
    // v1.5.2 C-TB: bec60c54b, package-manager.test.ts:2962. A branch ref moves.
    #expect(collector.snapshot().contains { $0.contains("git fetch origin main") })
    #expect(try getFileContent(repoDir: cachedDir, filename: "pi-extensions/session-breakdown.ts") == "// pinned")
    #else
    Issue.record("CryptoKit unavailable")
    #endif
}

// v1.5.2 C-TB: e3da248ea, package-manager.ts:2149-2180.
@Test(.timeLimit(.minutes(1))) func gitUpdateMarkerRetriesAfterResetAndCleanFailures() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctb-git-marker-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let bare = root.appendingPathComponent("bare.git")
    let seed = root.appendingPathComponent("seed")
    let agent = root.appendingPathComponent("agent")
    let installed = agent.appendingPathComponent("git/github.com/test/extension")
    try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
    _ = try git(["init", "--bare", bare.path], cwd: root.path)
    _ = try git(["clone", bare.path, seed.path], cwd: root.path)
    _ = try git(["config", "user.email", "test@test.com"], cwd: seed.path)
    _ = try git(["config", "user.name", "Test"], cwd: seed.path)
    _ = try createCommit(repoDir: seed.path, filename: "extension.swift", content: "// one", message: "one")
    _ = try git(["push", "origin", "HEAD:main"], cwd: seed.path)
    _ = try git(["symbolic-ref", "HEAD", "refs/heads/main"], cwd: bare.path)
    try FileManager.default.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
    _ = try git(["clone", bare.path, installed.path], cwd: root.path)
    let nextHead = try createCommit(repoDir: seed.path, filename: "extension.swift", content: "// two", message: "two")
    _ = try git(["push", "origin", "HEAD:main"], cwd: seed.path)
    let marker = installed.deletingLastPathComponent().appendingPathComponent(".extension.pi-update-incomplete")
    let settings = SettingsManager.inMemory()
    settings.setPackages([.simple("git:github.com/test/extension")])
    let manager = DefaultPackageManager(cwd: root.path, agentDir: agent.path, settingsManager: settings)
    let phase = LockedState(0)
    let markerSeenBeforeReset = LockedState(false)
    manager.setCommandRunnerForTests { command, args, cwd in
        if command == "git" && args.first == "reset" && phase.withLock({ $0 }) == 0 {
            markerSeenBeforeReset.withLock { $0 = FileManager.default.fileExists(atPath: marker.path) }
            throw URLError(.cannotWriteToFile)
        }
        if command == "git" && args.first == "clean" && phase.withLock({ $0 }) == 1 {
            throw URLError(.cannotWriteToFile)
        }
        let result = try await execCommand("/usr/bin/git", args, cwd)
        if result.code != 0 { throw URLError(.badServerResponse) }
        return result
    }
    do { try await manager.update(nil); Issue.record("reset should fail") } catch { }
    #expect(markerSeenBeforeReset.withLock { $0 })
    #expect(FileManager.default.fileExists(atPath: marker.path))
    phase.withLock { $0 = 1 }
    try await manager.update(nil)
    #expect(try git(["rev-parse", "HEAD"], cwd: installed.path) == nextHead)
    #expect(FileManager.default.fileExists(atPath: marker.path))
    phase.withLock { $0 = 2 }
    try await manager.update(nil)
    #expect(!FileManager.default.fileExists(atPath: marker.path))
}

// v1.5.2 C-TB: bec60c54b, package-manager.test.ts:2979-2993.
@Test(.timeLimit(.minutes(1))) func temporaryCheckedOutCommitSkipsGitFetch() async throws {
    #if canImport(CryptoKit)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctb-git-hash-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let packagePath = "test/commit-skip-\(UUID().uuidString.lowercased())"
    let source = "git:github.com/\(packagePath)"
    let head = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    let ref = String(head.prefix(12))
    let manager = DefaultPackageManager(cwd: root.path, agentDir: root.path, settingsManager: .inMemory())
    let path = manager.temporaryGitDirectory(host: "github.com", path: packagePath, ref: ref)
    try FileManager.default.createDirectory(at: URL(fileURLWithPath: path), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: path) }
    let calls = LockedState<[[String]]>([])
    manager.setCommandRunnerForTests { command, args, _ in
        if command == "git" { calls.withLock { $0.append(args) } }
        return ExecResult(stdout: args == ["rev-parse", "HEAD"] ? head : "", stderr: "", code: 0, killed: false)
    }
    _ = try await manager.resolveExtensionSources(["\(source)@\(ref)"], options: .init(temporary: true))
    #expect(calls.withLock { $0 } == [["rev-parse", "HEAD"]])
    #endif
}
