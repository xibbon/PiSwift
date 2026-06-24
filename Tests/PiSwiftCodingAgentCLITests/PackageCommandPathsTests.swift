import Foundation
import Testing
@testable import PiSwiftCodingAgent
@testable import PiSwiftCodingAgentCLI
import Darwin

private func readSettingsPackages(_ settingsPath: String) -> [String] {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let packages = json["packages"] as? [Any] else {
        return []
    }
    return packages.compactMap { $0 as? String }
}

@MainActor
private func captureFD(_ fd: Int32, operation: () async -> Void) async -> String {
    fflush(fd == STDOUT_FILENO ? stdout : stderr)
    let pipeFDs = UnsafeMutablePointer<Int32>.allocate(capacity: 2)
    defer { pipeFDs.deallocate() }
    guard pipe(pipeFDs) == 0 else { return "" }
    defer {
        close(pipeFDs[0])
        close(pipeFDs[1])
    }

    let savedFD = dup(fd)
    guard savedFD >= 0 else { return "" }
    defer { close(savedFD) }

    guard dup2(pipeFDs[1], fd) >= 0 else { return "" }

    await operation()
    fflush(fd == STDOUT_FILENO ? stdout : stderr)
    _ = dup2(savedFD, fd)
    close(pipeFDs[1])

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = read(pipeFDs[0], &buffer, buffer.count)
        if count <= 0 { break }
        data.append(buffer, count: Int(count))
    }
    return String(decoding: data, as: UTF8.self)
}

@MainActor @Test(.disabled("Flaky: changeCurrentDirectoryPath interferes with parallel tests"))
func packageCommandsPersistRelativeLocalPaths() async {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pi-package-commands-\(UUID().uuidString)").path
    let agentDir = URL(fileURLWithPath: tempDir).appendingPathComponent("agent").path
    let projectDir = URL(fileURLWithPath: tempDir).appendingPathComponent("project").path
    let packageDir = URL(fileURLWithPath: projectDir).appendingPathComponent("packages/local-package").path

    try? FileManager.default.createDirectory(atPath: agentDir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(atPath: packageDir, withIntermediateDirectories: true)

    let originalCwd = FileManager.default.currentDirectoryPath
    let originalAgentDir = ProcessInfo.processInfo.environment[ENV_AGENT_DIR]
    setenv(ENV_AGENT_DIR, agentDir, 1)
    FileManager.default.changeCurrentDirectoryPath(projectDir)
    defer {
        FileManager.default.changeCurrentDirectoryPath(originalCwd)
        if let originalAgentDir {
            setenv(ENV_AGENT_DIR, originalAgentDir, 1)
        } else {
            unsetenv(ENV_AGENT_DIR)
        }
        try? FileManager.default.removeItem(atPath: tempDir)
    }

    _ = await handlePackageCommand(["install", "./packages/local-package"])

    let settingsPath = URL(fileURLWithPath: agentDir).appendingPathComponent("settings.json").path
    let packages = readSettingsPackages(settingsPath)
    #expect(packages.count == 1)
    guard let stored = packages.first else {
        Issue.record("Expected stored package path")
        return
    }
    let resolvedFromSettings = URL(fileURLWithPath: agentDir).appendingPathComponent(stored).resolvingSymlinksInPath().path
    let resolvedPackageDir = URL(fileURLWithPath: packageDir).resolvingSymlinksInPath().path
    #expect(resolvedFromSettings == resolvedPackageDir)
}

@MainActor @Test(.disabled("Flaky: changeCurrentDirectoryPath interferes with parallel tests"))
func packageCommandsRemoveTrailingSlash() async {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pi-package-commands-remove-\(UUID().uuidString)").path
    let agentDir = URL(fileURLWithPath: tempDir).appendingPathComponent("agent").path
    let projectDir = URL(fileURLWithPath: tempDir).appendingPathComponent("project").path
    let packageDir = URL(fileURLWithPath: tempDir).appendingPathComponent("local-package").path

    try? FileManager.default.createDirectory(atPath: agentDir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(atPath: projectDir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(atPath: packageDir, withIntermediateDirectories: true)

    let originalCwd = FileManager.default.currentDirectoryPath
    let originalAgentDir = ProcessInfo.processInfo.environment[ENV_AGENT_DIR]
    setenv(ENV_AGENT_DIR, agentDir, 1)
    FileManager.default.changeCurrentDirectoryPath(projectDir)
    defer {
        FileManager.default.changeCurrentDirectoryPath(originalCwd)
        if let originalAgentDir {
            setenv(ENV_AGENT_DIR, originalAgentDir, 1)
        } else {
            unsetenv(ENV_AGENT_DIR)
        }
        try? FileManager.default.removeItem(atPath: tempDir)
    }

    _ = await handlePackageCommand(["install", "\(packageDir)/"])

    let settingsPath = URL(fileURLWithPath: agentDir).appendingPathComponent("settings.json").path
    #expect(readSettingsPackages(settingsPath).count == 1)

    _ = await handlePackageCommand(["remove", "\(packageDir)/"])
    #expect(readSettingsPackages(settingsPath).isEmpty)
}

@Suite("Package command UX", .serialized)
struct PackageCommandUxTests {
    @MainActor @Test
    func installHelpShowsUsage() async {
        let stdout = await captureFD(STDOUT_FILENO) {
            _ = await handlePackageCommand(["install", "--help"])
        }
        #expect(stdout.contains("Usage:"))
        #expect(stdout.contains("pi install <source> [-l]"))
        #expect(consumePackageCommandExitCode() == nil)
    }

    @MainActor @Test
    func unknownInstallOptionShowsFriendlyError() async {
        let stderr = await captureFD(STDERR_FILENO) {
            _ = await handlePackageCommand(["install", "--unknown"])
        }
        #expect(stderr.contains("Unknown option --unknown for \"install\"."))
        #expect(stderr.contains("Use \"pi --help\" or \"pi install <source> [-l]\"."))
        #expect(consumePackageCommandExitCode() == 1)
    }

    @MainActor @Test
    func missingInstallSourceShowsUsage() async {
        let stderr = await captureFD(STDERR_FILENO) {
            _ = await handlePackageCommand(["install"])
        }
        #expect(stderr.contains("Missing install source."))
        #expect(stderr.contains("Usage: pi install <source> [-l]"))
        #expect(consumePackageCommandExitCode() == 1)
    }

    @MainActor @Test
    func offlineInstallFailsBeforePackageResolution() async {
        let stderr = await captureFD(STDERR_FILENO) {
            _ = await handlePackageCommand(["install", "npm:test-package"], offline: true)
        }
        #expect(stderr.contains("Offline mode is enabled; package install is unavailable."))
        #expect(consumePackageCommandExitCode() == 1)
    }
}
