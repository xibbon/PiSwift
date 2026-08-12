import Foundation
import Testing
@testable import PiSwiftCodingAgent

// MARK: - Helper functions

private func isEnabled(_ r: ResolvedResource, _ pathMatch: String, matchFn: MatchMode = .endsWith) -> Bool {
    switch matchFn {
    case .endsWith:
        return r.path.hasSuffix(pathMatch) && r.enabled
    case .includes:
        return r.path.contains(pathMatch) && r.enabled
    }
}

private func isDisabled(_ r: ResolvedResource, _ pathMatch: String, matchFn: MatchMode = .endsWith) -> Bool {
    switch matchFn {
    case .endsWith:
        return r.path.hasSuffix(pathMatch) && !r.enabled
    case .includes:
        return r.path.contains(pathMatch) && !r.enabled
    }
}

private enum MatchMode {
    case endsWith
    case includes
}

// MARK: - Test fixture

private final class PackageManagerTestFixture {
    let tempDir: String
    let agentDir: String
    let settingsManager: SettingsManager
    let packageManager: DefaultPackageManager
    let previousHome: String?

    init() throws {
        let uuid = UUID().uuidString
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pm-test-\(uuid)")
            .path

        agentDir = URL(fileURLWithPath: tempDir).appendingPathComponent("agent").path

        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: agentDir, withIntermediateDirectories: true)

        // Isolate `$HOME` so the package manager's auto-discovery of `~/.agents/skills`
        // doesn't leak the developer's locally-installed skills into tests. Mirrors upstream
        // `process.env.HOME` isolation in vitest setup. Use a dedicated `home` subdirectory
        // (NOT `tempDir` itself) so tests that create `tempDir/.agents/skills/` for ancestor-
        // walk fixtures don't accidentally double as the fake user home.
        previousHome = ProcessInfo.processInfo.environment["HOME"]
        let fakeHome = URL(fileURLWithPath: tempDir).appendingPathComponent("home").path
        try FileManager.default.createDirectory(atPath: fakeHome, withIntermediateDirectories: true)
        setenv("HOME", fakeHome, 1)

        settingsManager = SettingsManager.inMemory()
        packageManager = DefaultPackageManager(cwd: tempDir, agentDir: agentDir, settingsManager: settingsManager)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: tempDir)
        if let previousHome {
            setenv("HOME", previousHome, 1)
        } else {
            unsetenv("HOME")
        }
    }

    func createDir(_ relativePath: String) throws -> String {
        let path = URL(fileURLWithPath: tempDir).appendingPathComponent(relativePath).path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    func createAgentDir(_ relativePath: String) throws -> String {
        let path = URL(fileURLWithPath: agentDir).appendingPathComponent(relativePath).path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    func writeFile(_ relativePath: String, content: String) throws -> String {
        let path = URL(fileURLWithPath: tempDir).appendingPathComponent(relativePath).path
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    func writeAgentFile(_ relativePath: String, content: String) throws -> String {
        let path = URL(fileURLWithPath: agentDir).appendingPathComponent(relativePath).path
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }
}

// MARK: - Event collector for progress callback tests

private final class EventCollector: @unchecked Sendable {
    private var _events: [ProgressEvent] = []
    private let lock = NSLock()

    var events: [ProgressEvent] {
        lock.lock()
        defer { lock.unlock() }
        return _events
    }

    func append(_ event: ProgressEvent) {
        lock.lock()
        defer { lock.unlock() }
        _events.append(event)
    }
}

private final class CommandRecorder: @unchecked Sendable {
    private var _calls: [(command: String, args: [String], cwd: String)] = []
    private let lock = NSLock()

    var calls: [(command: String, args: [String], cwd: String)] {
        lock.lock()
        defer { lock.unlock() }
        return _calls
    }

    func append(command: String, args: [String], cwd: String) {
        lock.lock()
        defer { lock.unlock() }
        _calls.append((command, args, cwd))
    }
}

// MARK: - resolve tests

@Test func resolveReturnsEmptyPathsWhenNoSourcesConfigured() async throws {
    let fixture = try PackageManagerTestFixture()
    let result = try await fixture.packageManager.resolve()
    #expect(result.extensions.isEmpty)
    #expect(result.skills.isEmpty)
    #expect(result.prompts.isEmpty)
    #expect(result.themes.isEmpty)
}

@Test func resolveLocalExtensionPathsFromSettings() async throws {
    let fixture = try PackageManagerTestFixture()
    let extPath = try fixture.writeAgentFile("extensions/my-extension.ts", content: "export default function() {}")
    fixture.settingsManager.setExtensionPaths(["extensions/my-extension.ts"])

    let result = try await fixture.packageManager.resolve()
    #expect(result.extensions.contains { $0.path == extPath && $0.enabled })
}

@Test func resolveProjectPathsRelativeToPi() async throws {
    let fixture = try PackageManagerTestFixture()
    let extPath = try fixture.writeFile(".pi/extensions/project-ext.ts", content: "export default function() {}")
    fixture.settingsManager.setProjectExtensionPaths(["extensions/project-ext.ts"])

    let result = try await fixture.packageManager.resolve()
    #expect(result.extensions.contains { $0.path == extPath && $0.enabled })
}


// MARK: - resolveExtensionSources tests

@Test func resolveExtensionSourcesResolvesLocalPaths() async throws {
    let fixture = try PackageManagerTestFixture()
    let extPath = try fixture.writeFile("ext.ts", content: "export default function() {}")

    // Pass relative path since resolveExtensionSources resolves relative to cwd
    let result = try await fixture.packageManager.resolveExtensionSources(["ext.ts"])
    #expect(result.extensions.contains { $0.path == extPath && $0.enabled })
}

@Test func resolveExtensionSourcesHandlesDirectoriesWithPiManifest() async throws {
    let fixture = try PackageManagerTestFixture()
    _ = try fixture.createDir("my-package")

    let manifestContent = """
    {
        "name": "my-package",
        "pi": {
            "extensions": ["./src/index.ts"],
            "skills": ["./skills"]
        }
    }
    """
    _ = try fixture.writeFile("my-package/package.json", content: manifestContent)
    _ = try fixture.writeFile("my-package/src/index.ts", content: "export default function() {}")
    _ = try fixture.writeFile(
        "my-package/skills/my-skill/SKILL.md",
        content: "---\nname: my-skill\ndescription: Test\n---\nContent"
    )

    let result = try await fixture.packageManager.resolveExtensionSources(["my-package"])
    #expect(result.extensions.contains { $0.path.hasSuffix("src/index.ts") && $0.enabled })
    #expect(result.skills.contains { $0.path.hasSuffix("my-skill/SKILL.md") && $0.enabled })
}

@Test func malformedManifestResourceArraysDoNotAbortPackageResolution() async throws {
    let fixture = try PackageManagerTestFixture()
    _ = try fixture.createDir("malformed-package")
    let manifestContent = """
    {
        "name": "malformed-package",
        "pi": {
            "extensions": ["./extensions/main.ts"],
            "skills": [42, "./skills"],
            "prompts": {"path": "./prompts"},
            "themes": "./themes"
        }
    }
    """
    _ = try fixture.writeFile("malformed-package/package.json", content: manifestContent)
    _ = try fixture.writeFile("malformed-package/extensions/main.ts", content: "export default function() {}")

    let result = try await fixture.packageManager.resolveExtensionSources(["malformed-package"])
    #expect(result.extensions.contains { $0.path.hasSuffix("extensions/main.ts") && $0.enabled })
}

@Test func resolveExtensionSourcesHandlesAutoDiscoveryLayout() async throws {
    let fixture = try PackageManagerTestFixture()
    _ = try fixture.createDir("auto-pkg")
    _ = try fixture.writeFile("auto-pkg/extensions/main.ts", content: "export default function() {}")
    _ = try fixture.writeFile("auto-pkg/themes/dark.json", content: "{}")

    let result = try await fixture.packageManager.resolveExtensionSources(["auto-pkg"])
    #expect(result.extensions.contains { $0.path.hasSuffix("main.ts") && $0.enabled })
    #expect(result.themes.contains { $0.path.hasSuffix("dark.json") && $0.enabled })
}

@Test func autoDiscoveryScansAncestorAgentsSkillsUpToGitRoot() async throws {
    let fixture = try PackageManagerTestFixture()
    let repoRoot = URL(fileURLWithPath: fixture.tempDir).appendingPathComponent("repo").path
    let nestedCwd = URL(fileURLWithPath: repoRoot).appendingPathComponent("packages").appendingPathComponent("feature").path
    try FileManager.default.createDirectory(atPath: nestedCwd, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: URL(fileURLWithPath: repoRoot).appendingPathComponent(".git").path, withIntermediateDirectories: true)

    let aboveRepoSkill = URL(fileURLWithPath: fixture.tempDir)
        .appendingPathComponent(".agents").appendingPathComponent("skills").appendingPathComponent("above-repo").appendingPathComponent("SKILL.md").path
    try FileManager.default.createDirectory(
        atPath: URL(fileURLWithPath: aboveRepoSkill).deletingLastPathComponent().path,
        withIntermediateDirectories: true
    )
    try "---\nname: above-repo\ndescription: above\n---\n".write(toFile: aboveRepoSkill, atomically: true, encoding: .utf8)

    let repoRootSkill = URL(fileURLWithPath: repoRoot)
        .appendingPathComponent(".agents").appendingPathComponent("skills").appendingPathComponent("repo-root").appendingPathComponent("SKILL.md").path
    try FileManager.default.createDirectory(
        atPath: URL(fileURLWithPath: repoRootSkill).deletingLastPathComponent().path,
        withIntermediateDirectories: true
    )
    try "---\nname: repo-root\ndescription: repo\n---\n".write(toFile: repoRootSkill, atomically: true, encoding: .utf8)

    let nestedSkill = URL(fileURLWithPath: repoRoot)
        .appendingPathComponent("packages").appendingPathComponent(".agents").appendingPathComponent("skills").appendingPathComponent("nested").appendingPathComponent("SKILL.md").path
    try FileManager.default.createDirectory(
        atPath: URL(fileURLWithPath: nestedSkill).deletingLastPathComponent().path,
        withIntermediateDirectories: true
    )
    try "---\nname: nested\ndescription: nested\n---\n".write(toFile: nestedSkill, atomically: true, encoding: .utf8)

    let manager = DefaultPackageManager(cwd: nestedCwd, agentDir: fixture.agentDir, settingsManager: fixture.settingsManager)
    let result = try await manager.resolve()

    let repoRootSkillResolved = URL(fileURLWithPath: repoRootSkill).resolvingSymlinksInPath().path
    let nestedSkillResolved = URL(fileURLWithPath: nestedSkill).resolvingSymlinksInPath().path
    let aboveRepoSkillResolved = URL(fileURLWithPath: aboveRepoSkill).resolvingSymlinksInPath().path
    #expect(result.skills.contains { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == repoRootSkillResolved && $0.enabled })
    #expect(result.skills.contains { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == nestedSkillResolved && $0.enabled })
    #expect(!result.skills.contains { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == aboveRepoSkillResolved })
}

@Test func autoDiscoveryScansAncestorAgentsSkillsWithoutGitRepo() async throws {
    let fixture = try PackageManagerTestFixture()
    let nonRepoRoot = URL(fileURLWithPath: fixture.tempDir).appendingPathComponent("non-repo").path
    let nestedCwd = URL(fileURLWithPath: nonRepoRoot).appendingPathComponent("a").appendingPathComponent("b").path
    try FileManager.default.createDirectory(atPath: nestedCwd, withIntermediateDirectories: true)

    let rootSkill = URL(fileURLWithPath: nonRepoRoot)
        .appendingPathComponent(".agents").appendingPathComponent("skills").appendingPathComponent("root").appendingPathComponent("SKILL.md").path
    try FileManager.default.createDirectory(
        atPath: URL(fileURLWithPath: rootSkill).deletingLastPathComponent().path,
        withIntermediateDirectories: true
    )
    try "---\nname: root\ndescription: root\n---\n".write(toFile: rootSkill, atomically: true, encoding: .utf8)

    let middleSkill = URL(fileURLWithPath: nonRepoRoot)
        .appendingPathComponent("a").appendingPathComponent(".agents").appendingPathComponent("skills").appendingPathComponent("middle").appendingPathComponent("SKILL.md").path
    try FileManager.default.createDirectory(
        atPath: URL(fileURLWithPath: middleSkill).deletingLastPathComponent().path,
        withIntermediateDirectories: true
    )
    try "---\nname: middle\ndescription: middle\n---\n".write(toFile: middleSkill, atomically: true, encoding: .utf8)

    let manager = DefaultPackageManager(cwd: nestedCwd, agentDir: fixture.agentDir, settingsManager: fixture.settingsManager)
    let result = try await manager.resolve()
    let rootSkillResolved = URL(fileURLWithPath: rootSkill).resolvingSymlinksInPath().path
    let middleSkillResolved = URL(fileURLWithPath: middleSkill).resolvingSymlinksInPath().path
    #expect(result.skills.contains { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == rootSkillResolved && $0.enabled })
    #expect(result.skills.contains { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == middleSkillResolved && $0.enabled })
}

// MARK: - progress callback tests

@Test func progressCallbackEmitsEvents() async throws {
    let fixture = try PackageManagerTestFixture()
    let collector = EventCollector()
    fixture.packageManager.setProgressCallback { event in
        collector.append(event)
    }

    let _ = try fixture.writeFile("ext.ts", content: "export default function() {}")

    // Local paths don't trigger install progress
    _ = try await fixture.packageManager.resolveExtensionSources(["ext.ts"])

    // For local paths, no events are emitted
    #expect(collector.events.isEmpty)
}

// MARK: - source parsing tests

@Test func sourceParsingEmitsProgressEventsOnInstallAttempt() async throws {
    let fixture = try PackageManagerTestFixture()
    let collector = EventCollector()
    fixture.packageManager.setProgressCallback { event in
        collector.append(event)
    }

    // Use public install method which emits progress events
    do {
        try await fixture.packageManager.install("npm:nonexistent-package@1.0.0")
    } catch {
        // Expected to fail - package doesn't exist
    }

    // Should have emitted start event before failure
    #expect(collector.events.contains { $0.type == "start" && $0.action == "install" })
    // Should have emitted error event
    #expect(collector.events.contains { $0.type == "error" })
}

@Test func sourceParsingRecognizesGithubURLsWithoutGitPrefix() async throws {
    let fixture = try PackageManagerTestFixture()
    let collector = EventCollector()
    fixture.packageManager.setProgressCallback { event in
        collector.append(event)
    }

    // Prevent git from prompting for credentials (which blocks the test runner)
    let previousValue = ProcessInfo.processInfo.environment["GIT_TERMINAL_PROMPT"]
    setenv("GIT_TERMINAL_PROMPT", "0", 1)
    defer {
        if let previousValue {
            setenv("GIT_TERMINAL_PROMPT", previousValue, 1)
        } else {
            unsetenv("GIT_TERMINAL_PROMPT")
        }
    }

    // This should be parsed as a git source, not throw "unsupported"
    do {
        try await fixture.packageManager.install("https://github.com/nonexistent/repo")
    } catch {
        // Expected to fail - repo doesn't exist
    }

    // Should have attempted clone, not thrown unsupported error
    #expect(collector.events.contains { $0.type == "start" && $0.action == "install" })
}

@Test func addSourceToSettingsNormalizesLocalUserPackageWithDotPrefix() async throws {
    let fixture = try PackageManagerTestFixture()
    _ = try fixture.createDir("local-package")

    let added = fixture.packageManager.addSourceToSettings("local-package", local: false)
    #expect(added)

    let packages = fixture.settingsManager.getGlobalSettings().packages
    #expect(packages?.count == 1)
    if case .simple(let source)? = packages?.first {
        #expect(source == "../local-package")
    } else {
        Issue.record("Expected a simple package source")
    }
}

@Test func addSourceToSettingsNormalizesLocalProjectPackageWithDotPrefix() async throws {
    let fixture = try PackageManagerTestFixture()
    _ = try fixture.createDir("project-local")

    let added = fixture.packageManager.addSourceToSettings("project-local", local: true)
    #expect(added)

    let packages = fixture.settingsManager.getProjectSettings().packages
    #expect(packages?.count == 1)
    if case .simple(let source)? = packages?.first {
        #expect(source == "../project-local")
    } else {
        Issue.record("Expected a simple package source")
    }
}

// MARK: - Git URL parsing tests

@Test func parseSourceSupportsProtocolGitUrls() async throws {
    let fixture = try PackageManagerTestFixture()
    let parsed = fixture.packageManager.parseSource("ssh://git@github.com/user/repo")
    if case .git(let git) = parsed {
        #expect(git.host == "github.com")
        #expect(git.path == "user/repo")
        #expect(git.repo == "ssh://git@github.com/user/repo")
    } else {
        Issue.record("Expected git source")
    }
}

@Test func parseSourceSupportsGitPrefixShorthandUrls() async throws {
    let fixture = try PackageManagerTestFixture()
    let parsed = fixture.packageManager.parseSource("git:git@github.com:user/repo")
    if case .git(let git) = parsed {
        #expect(git.host == "github.com")
        #expect(git.path == "user/repo")
        #expect(git.repo == "git@github.com:user/repo")
        #expect(git.ref == nil)
        #expect(git.pinned == false)
    } else {
        Issue.record("Expected git source")
    }
}

@Test func parseSourceSupportsGitPrefixShorthandWithRef() async throws {
    let fixture = try PackageManagerTestFixture()
    let parsed = fixture.packageManager.parseSource("git:git@github.com:user/repo@v1.0.0")
    if case .git(let git) = parsed {
        #expect(git.host == "github.com")
        #expect(git.path == "user/repo")
        #expect(git.repo == "git@github.com:user/repo")
        #expect(git.ref == "v1.0.0")
        #expect(git.pinned == true)
    } else {
        Issue.record("Expected git source")
    }
}

@Test func parseSourceRejectsShorthandWithoutGitPrefix() async throws {
    let fixture = try PackageManagerTestFixture()
    let parsed = fixture.packageManager.parseSource("git@github.com:user/repo.git")
    if case .local(let local) = parsed {
        #expect(local.path == "git@github.com:user/repo.git")
    } else {
        Issue.record("Expected local source")
    }

    let shorthand = fixture.packageManager.parseSource("github.com/user/repo")
    if case .local(let local) = shorthand {
        #expect(local.path == "github.com/user/repo")
    } else {
        Issue.record("Expected local source")
    }
}

@Test func packageIdentityNormalizesGitUrls() async throws {
    let fixture = try PackageManagerTestFixture()
    let sshIdentity = fixture.packageManager.getPackageIdentity("git:git@github.com:user/repo")
    let httpsIdentity = fixture.packageManager.getPackageIdentity("https://github.com/user/repo")
    #expect(sshIdentity == httpsIdentity)
    #expect(sshIdentity == "git:github.com/user/repo")
}

@Test func packageIdentityIgnoresRefs() async throws {
    let fixture = try PackageManagerTestFixture()
    let withRef = fixture.packageManager.getPackageIdentity("git:git@github.com:user/repo@v1.0.0")
    let withoutRef = fixture.packageManager.getPackageIdentity("git:git@github.com:user/repo")
    #expect(withRef == withoutRef)
}

@Test func parseSourceSupportsEnterpriseHosts() async throws {
    let fixture = try PackageManagerTestFixture()
    let parsed = fixture.packageManager.parseSource("git:github.tools.sap/agent-dev/sap-pie@v1")
    if case .git(let git) = parsed {
        #expect(git.host == "github.tools.sap")
        #expect(git.path == "agent-dev/sap-pie")
        #expect(git.ref == "v1")
        #expect(git.repo == "https://github.tools.sap/agent-dev/sap-pie")
        #expect(git.pinned == true)
    } else {
        Issue.record("Expected git source")
    }
}

@Test func sshInstallEmitsStartEvent() async throws {
    let fixture = try PackageManagerTestFixture()
    let collector = EventCollector()
    fixture.packageManager.setProgressCallback { event in
        collector.append(event)
    }

    let previousValue = ProcessInfo.processInfo.environment["GIT_TERMINAL_PROMPT"]
    setenv("GIT_TERMINAL_PROMPT", "0", 1)
    defer {
        if let previousValue {
            setenv("GIT_TERMINAL_PROMPT", previousValue, 1)
        } else {
            unsetenv("GIT_TERMINAL_PROMPT")
        }
    }

    do {
        try await fixture.packageManager.install("git:git@github.com:nonexistent/repo")
    } catch {
        // Expected to fail
    }

    #expect(collector.events.contains { $0.type == "start" && $0.action == "install" })
}

@Test func sshProtocolInstallEmitsStartEvent() async throws {
    let fixture = try PackageManagerTestFixture()
    let collector = EventCollector()
    fixture.packageManager.setProgressCallback { event in
        collector.append(event)
    }

    let previousValue = ProcessInfo.processInfo.environment["GIT_TERMINAL_PROMPT"]
    setenv("GIT_TERMINAL_PROMPT", "0", 1)
    defer {
        if let previousValue {
            setenv("GIT_TERMINAL_PROMPT", previousValue, 1)
        } else {
            unsetenv("GIT_TERMINAL_PROMPT")
        }
    }

    do {
        try await fixture.packageManager.install("ssh://git@github.com/nonexistent/repo")
    } catch {
        // Expected to fail
    }

    #expect(collector.events.contains { $0.type == "start" && $0.action == "install" })
}

// MARK: - pattern filtering in pi manifest tests

@Test func manifestSupportGlobPatternsInExtensions() async throws {
    let fixture = try PackageManagerTestFixture()
    _ = try fixture.createDir("manifest-pkg")
    _ = try fixture.writeFile("manifest-pkg/extensions/local.ts", content: "export default function() {}")
    _ = try fixture.writeFile("manifest-pkg/node_modules/dep/extensions/remote.ts", content: "export default function() {}")
    _ = try fixture.writeFile("manifest-pkg/node_modules/dep/extensions/skip.ts", content: "export default function() {}")
    let manifestContent = """
    {
        "name": "manifest-pkg",
        "pi": {
            "extensions": ["extensions", "node_modules/dep/extensions", "!**/skip.ts"]
        }
    }
    """
    _ = try fixture.writeFile("manifest-pkg/package.json", content: manifestContent)

    let result = try await fixture.packageManager.resolveExtensionSources(["manifest-pkg"])
    #expect(result.extensions.contains { isEnabled($0, "local.ts") })
    #expect(result.extensions.contains { isEnabled($0, "remote.ts") })
    #expect(!result.extensions.contains { $0.path.hasSuffix("skip.ts") })
}

@Test func manifestSupportGlobPatternsInSkills() async throws {
    let fixture = try PackageManagerTestFixture()
    _ = try fixture.createDir("skill-manifest-pkg")
    _ = try fixture.writeFile(
        "skill-manifest-pkg/skills/good-skill/SKILL.md",
        content: "---\nname: good-skill\ndescription: Good\n---\nContent"
    )
    _ = try fixture.writeFile(
        "skill-manifest-pkg/skills/bad-skill/SKILL.md",
        content: "---\nname: bad-skill\ndescription: Bad\n---\nContent"
    )
    let manifestContent = """
    {
        "name": "skill-manifest-pkg",
        "pi": {
            "skills": ["skills", "!**/bad-skill"]
        }
    }
    """
    _ = try fixture.writeFile("skill-manifest-pkg/package.json", content: manifestContent)

    let result = try await fixture.packageManager.resolveExtensionSources(["skill-manifest-pkg"])
    #expect(result.skills.contains { isEnabled($0, "good-skill", matchFn: .includes) })
    #expect(!result.skills.contains { $0.path.contains("bad-skill") })
}

// MARK: - multi-file extension discovery tests

@Test func multiFileExtensionDiscoveryOnlyLoadIndexTs() async throws {
    let fixture = try PackageManagerTestFixture()
    _ = try fixture.createDir("multifile-pkg")
    _ = try fixture.writeFile(
        "multifile-pkg/extensions/subagent/index.ts",
        content: """
        import { helper } from "./agents.js";
        export default function(api) { api.registerTool({ name: "test", description: "test", execute: async () => helper() }); }
        """
    )
    // Helper module (should NOT be loaded as standalone extension)
    _ = try fixture.writeFile(
        "multifile-pkg/extensions/subagent/agents.ts",
        content: "export function helper() { return \"helper\"; }"
    )
    // Top-level extension file (should be loaded)
    _ = try fixture.writeFile("multifile-pkg/extensions/standalone.ts", content: "export default function(api) {}")

    let result = try await fixture.packageManager.resolveExtensionSources(["multifile-pkg"])

    // Should find the index.ts and standalone.ts
    #expect(result.extensions.contains { $0.path.hasSuffix("subagent/index.ts") && $0.enabled })
    #expect(result.extensions.contains { $0.path.hasSuffix("standalone.ts") && $0.enabled })

    // Should NOT find agents.ts as a standalone extension
    #expect(!result.extensions.contains { $0.path.hasSuffix("agents.ts") })
}

@Test func multiFileExtensionDiscoveryHandlesMixedTopLevelAndSubdirs() async throws {
    let fixture = try PackageManagerTestFixture()
    _ = try fixture.createDir("mixed-pkg")

    // Top-level extension
    _ = try fixture.writeFile("mixed-pkg/extensions/simple.ts", content: "export default function(api) {}")

    // Subdirectory with index.ts + helpers
    _ = try fixture.writeFile(
        "mixed-pkg/extensions/complex/index.ts",
        content: "import { a } from './a.js'; export default function(api) {}"
    )
    _ = try fixture.writeFile("mixed-pkg/extensions/complex/a.ts", content: "export const a = 1;")
    _ = try fixture.writeFile("mixed-pkg/extensions/complex/b.ts", content: "export const b = 2;")

    let result = try await fixture.packageManager.resolveExtensionSources(["mixed-pkg"])

    // Should find simple.ts and complex/index.ts
    #expect(result.extensions.contains { $0.path.hasSuffix("simple.ts") && $0.enabled })
    #expect(result.extensions.contains { $0.path.hasSuffix("complex/index.ts") && $0.enabled })

    // Should NOT find helper modules
    #expect(!result.extensions.contains { $0.path.hasSuffix("complex/a.ts") })
    #expect(!result.extensions.contains { $0.path.hasSuffix("complex/b.ts") })

    // Total should be exactly 2
    #expect(result.extensions.filter { $0.enabled }.count == 2)
}

@Test func multiFileExtensionDiscoverySkipsSubdirsWithoutIndexOrManifest() async throws {
    let fixture = try PackageManagerTestFixture()
    _ = try fixture.createDir("no-entry-pkg")

    // Subdirectory with no index.ts and no manifest
    _ = try fixture.writeFile("no-entry-pkg/extensions/broken/helper.ts", content: "export const x = 1;")
    _ = try fixture.writeFile("no-entry-pkg/extensions/broken/another.ts", content: "export const y = 2;")

    // Valid top-level extension
    _ = try fixture.writeFile("no-entry-pkg/extensions/valid.ts", content: "export default function(api) {}")

    let result = try await fixture.packageManager.resolveExtensionSources(["no-entry-pkg"])

    // Should only find the valid top-level extension
    #expect(result.extensions.contains { $0.path.hasSuffix("valid.ts") && $0.enabled })
    #expect(result.extensions.filter { $0.enabled }.count == 1)
}

// MARK: - Package source metadata tests

@Test func resolvedResourcesContainCorrectMetadata() async throws {
    let fixture = try PackageManagerTestFixture()
    let extPath = try fixture.writeAgentFile("extensions/test.ts", content: "export default function() {}")
    fixture.settingsManager.setExtensionPaths(["extensions/test.ts"])

    let result = try await fixture.packageManager.resolve()
    let resource = result.extensions.first { $0.path == extPath }
    #expect(resource != nil)
    #expect(resource?.metadata.scope == "user")
    #expect(resource?.metadata.origin == "top-level")
}

@Test func projectResourcesHaveProjectScope() async throws {
    let fixture = try PackageManagerTestFixture()
    let extPath = try fixture.writeFile(".pi/extensions/project.ts", content: "export default function() {}")
    fixture.settingsManager.setProjectExtensionPaths(["extensions/project.ts"])

    let result = try await fixture.packageManager.resolve()
    let resource = result.extensions.first { $0.path == extPath }
    #expect(resource != nil)
    #expect(resource?.metadata.scope == "project")
}

// MARK: - Package resolution with packages tests

@Test func resolvePackagesFromSettingsWithManifest() async throws {
    let fixture = try PackageManagerTestFixture()
    _ = try fixture.createDir("test-package")
    _ = try fixture.writeFile("test-package/extensions/pkg-ext.ts", content: "export default function() {}")
    // Need a manifest for the package to be properly resolved
    let manifestContent = """
    {
        "name": "test-package",
        "pi": {
            "extensions": ["extensions/pkg-ext.ts"]
        }
    }
    """
    _ = try fixture.writeFile("test-package/package.json", content: manifestContent)

    fixture.settingsManager.setPackages([.simple("test-package")])

    let result = try await fixture.packageManager.resolve()
    #expect(result.extensions.contains { $0.path.hasSuffix("pkg-ext.ts") && $0.enabled })
}

@Test func offlineResolveSkipsMissingNpmPackageWithoutNetworkCommand() async throws {
    let fixture = try PackageManagerTestFixture()
    fixture.settingsManager.setProjectPackages([.simple("npm:missing-package")])
    let manager = DefaultPackageManager(
        cwd: fixture.tempDir,
        agentDir: fixture.agentDir,
        settingsManager: fixture.settingsManager,
        offline: true
    )
    let recorder = CommandRecorder()
    manager.setCommandRunnerForTests { command, args, cwd in
        recorder.append(command: command, args: args, cwd: cwd)
        return ExecResult(stdout: "", stderr: "", code: 0, killed: false)
    }

    let result = try await manager.resolve()
    #expect(result.extensions.isEmpty)
    #expect(recorder.calls.isEmpty)
}

@Test func offlineResolveUsesInstalledUnpinnedNpmPackageWithoutCheckingLatest() async throws {
    let fixture = try PackageManagerTestFixture()
    let packageRoot = try fixture.createDir(".pi/npm/node_modules/test-package")
    let manifestContent = """
    {
        "name": "test-package",
        "version": "1.0.0",
        "pi": {
            "extensions": ["extensions/pkg-ext.ts"]
        }
    }
    """
    try manifestContent.write(
        toFile: URL(fileURLWithPath: packageRoot).appendingPathComponent("package.json").path,
        atomically: true,
        encoding: .utf8
    )
    _ = try fixture.writeFile(".pi/npm/node_modules/test-package/extensions/pkg-ext.ts", content: "export default function() {}")
    fixture.settingsManager.setProjectPackages([.simple("npm:test-package")])
    let manager = DefaultPackageManager(
        cwd: fixture.tempDir,
        agentDir: fixture.agentDir,
        settingsManager: fixture.settingsManager,
        offline: true
    )
    let recorder = CommandRecorder()
    manager.setCommandRunnerForTests { command, args, cwd in
        recorder.append(command: command, args: args, cwd: cwd)
        return ExecResult(stdout: "9.9.9\n", stderr: "", code: 0, killed: false)
    }

    let result = try await manager.resolve()
    #expect(result.extensions.contains { $0.path.hasSuffix("pkg-ext.ts") && $0.enabled })
    #expect(recorder.calls.isEmpty)
}

@Test func offlineInstallAndUpdateRejectNetworkPackageOperations() async throws {
    let fixture = try PackageManagerTestFixture()
    let manager = DefaultPackageManager(
        cwd: fixture.tempDir,
        agentDir: fixture.agentDir,
        settingsManager: fixture.settingsManager,
        offline: true
    )
    let recorder = CommandRecorder()
    manager.setCommandRunnerForTests { command, args, cwd in
        recorder.append(command: command, args: args, cwd: cwd)
        return ExecResult(stdout: "", stderr: "", code: 0, killed: false)
    }

    do {
        try await manager.install("npm:test-package")
        Issue.record("Expected offline npm install to throw")
    } catch {
        #expect(error.localizedDescription.contains("Offline mode is enabled"))
    }

    do {
        try await manager.update(nil)
        Issue.record("Expected offline package update to throw")
    } catch {
        #expect(error.localizedDescription.contains("Offline mode is enabled"))
    }

    #expect(recorder.calls.isEmpty)
}

// MARK: - getInstalledPath tests

@Test func getInstalledPathReturnsNilForNonexistent() async throws {
    let fixture = try PackageManagerTestFixture()
    let path = fixture.packageManager.getInstalledPath("npm:nonexistent", scope: "user")
    #expect(path == nil)
}
