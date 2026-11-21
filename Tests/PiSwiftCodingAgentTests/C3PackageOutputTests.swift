import Foundation
import Synchronization
import Testing
@testable import PiSwiftCodingAgent

private final class C3PackageFixture {
    let root: URL
    let bin: URL
    let settings = SettingsManager.inMemory()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("c3-package-\(UUID().uuidString)")
        bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("agent"), withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func script(_ name: String, _ body: String) throws {
        let url = bin.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func manager(_ output: PackageCommandOutput = .capture, ssh: String? = nil) -> DefaultPackageManager {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = bin.path + ":" + (environment["PATH"] ?? "")
        environment["GIT_SSH_COMMAND"] = ssh
        return DefaultPackageManager(cwd: root.path, agentDir: root.appendingPathComponent("agent").path,
            settingsManager: settings, commandOutput: output, commandEnvironment: environment)
    }
}

private func c3Failure(_ operation: () async throws -> Void) async -> String {
    do { try await operation(); return "" }
    catch { return error.localizedDescription }
}

@Test(.timeLimit(.minutes(1)))
func reportsTheEndOfAFailingCommandsOutputInTheError() async throws {
    let fixture = try C3PackageFixture()
    try fixture.script("npm", "printf 'npm out\\n'; printf 'npm ERR! broken\\n' >&2; exit 3")
    let message = await c3Failure { try await fixture.manager().install("npm:broken", options: PackageResolveOptions(local: true)) }
    #expect(message.contains("npm install"))
    #expect(message.contains("failed with code 3:\n"))
    #expect(message.contains("npm out"))
    #expect(message.contains("npm ERR! broken"))
}

@Test(.timeLimit(.minutes(1)))
func returnsWhenTheCommandExitsAlthoughABackgroundProcessStillHoldsItsOutput() async throws {
    let fixture = try C3PackageFixture()
    try fixture.script("npm", "sleep 5 &\nexit 0")
    let start = ContinuousClock.now
    try await fixture.manager().install("npm:background", options: PackageResolveOptions(local: true))
    #expect(ContinuousClock.now - start < .seconds(3))
}

@Test(.timeLimit(.minutes(1)))
func stopsGitAndSshFromPromptingAndNamesTheFixWhenGitCouldNotAskForCredentials() async throws {
    let fixture = try C3PackageFixture()
    try fixture.script("git", "printf 'prompt=%s ssh=%s\\n' \"$GIT_TERMINAL_PROMPT\" \"$GIT_SSH_COMMAND\"; printf 'fatal: could not read Username: terminal prompts disabled\\n' >&2; exit 128")
    let message = await c3Failure { try await fixture.manager().install("git:https://example.com/private.git") }
    #expect(message.contains("prompt=0 ssh=ssh -o BatchMode=yes"))
    #expect(message.contains("git cannot ask for a password or passphrase while pi runs. Set up a git credential helper or an ssh agent, or install the package once from the shell with `pi install <source>`."))
}

@Test(.timeLimit(.minutes(1)))
func capturedRunKeepsExactlyEightThousandTrailingCharacters() async throws {
    let fixture = try C3PackageFixture()
    try fixture.script("npm", "printf '%08100d' 0; printf 'TAIL'; exit 3")
    let message = await c3Failure { try await fixture.manager().install("npm:large", options: PackageResolveOptions(local: true)) }
    let tail = message.components(separatedBy: "failed with code 3:\n").last ?? ""
    #expect(tail.count == 8_000)
    #expect(tail == String(repeating: "0", count: 7_996) + "TAIL")
}

@Test(.timeLimit(.minutes(1)))
func capturedRunCountsUnicodeAsUtf16Units() async throws {
    let fixture = try C3PackageFixture()
    try fixture.script("npm", "i=0; while [ \"$i\" -lt 4100 ]; do printf '😀'; i=$((i+1)); done; exit 3")
    let message = await c3Failure { try await fixture.manager().install("npm:unicode", options: PackageResolveOptions(local: true)) }
    let tail = message.components(separatedBy: "failed with code 3:\n").last ?? ""
    #expect(tail == String(repeating: "😀", count: 4_000))
}

@Test(.timeLimit(.minutes(1)))
func keepsAUserGitSshCommand() async throws {
    let fixture = try C3PackageFixture()
    try fixture.script("git", "printf 'prompt=%s ssh=%s\\n' \"$GIT_TERMINAL_PROMPT\" \"$GIT_SSH_COMMAND\"; exit 2")
    let message = await c3Failure {
        try await fixture.manager(ssh: "ssh -i /tmp/custom-key").install("git:https://example.com/private.git")
    }
    #expect(message.contains("prompt=0 ssh=ssh -i /tmp/custom-key"))
    #expect(!message.contains("BatchMode=yes"))
}

@Test(.timeLimit(.minutes(1)))
func announcesAPackageThatResolveInstalls() async throws {
    let fixture = try C3PackageFixture()
    try fixture.script("npm", "exit 0")
    fixture.settings.setProjectPackages([.simple("npm:new-package")])
    let events = Mutex<[ProgressEvent]>([])
    let manager = fixture.manager()
    manager.setProgressCallback { event in events.withLock { $0.append(event) } }
    _ = try await manager.resolve()
    let recorded = events.withLock { $0 }
    #expect(recorded.contains { $0.type == "start" && $0.action == "install" &&
        $0.source == "npm:new-package" && $0.message == "Installing npm:new-package..." })
    #expect(recorded.contains { $0.type == "complete" && $0.action == "install" &&
        $0.source == "npm:new-package" && $0.message == nil })
}

@Test(.timeLimit(.minutes(1)))
func resolveInstallFailureSendsErrorProgress() async throws {
    let fixture = try C3PackageFixture()
    try fixture.script("npm", "printf 'npm ERR! broken\\n' >&2; exit 3")
    fixture.settings.setProjectPackages([.simple("npm:broken")])
    let events = Mutex<[ProgressEvent]>([])
    let manager = fixture.manager()
    manager.setProgressCallback { event in events.withLock { $0.append(event) } }
    let paths = try await manager.resolve()
    #expect(paths.installFailures.count == 1)
    let recorded = events.withLock { $0 }
    #expect(recorded.contains { $0.type == "start" && $0.source == "npm:broken" })
    #expect(recorded.contains { $0.type == "error" && $0.source == "npm:broken" &&
        $0.message?.contains("npm ERR! broken") == true })
}

@Test(.timeLimit(.minutes(1)))
func inheritKeepsTheExistingErrorText() async throws {
    let fixture = try C3PackageFixture()
    try fixture.script("npm", "printf 'private detail\\n' >&2; exit 3")
    let message = await c3Failure { try await fixture.manager(.inherit).install("npm:broken", options: PackageResolveOptions(local: true)) }
    #expect(message.contains("failed with code 3"))
    #expect(!message.contains("private detail"))
}
