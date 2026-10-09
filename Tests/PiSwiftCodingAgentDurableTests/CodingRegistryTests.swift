import PiSwiftCodingAgent
import PiSwiftCodingAgentDurable
import PiSwiftDurable
import Testing

@Test func codingRegistryInstallsOnlyCodingToolsAndPiPrompt() throws {
    let registry = try createCodingRegistry(settingsManager: .inMemory(), cwd: "/project")
    let snapshot = registry.snapshot()
    #expect(snapshot.installed().map(\.name) == ["coding-tools", "pi-prompt"])
    #expect(snapshot.tools().map { $0.tool.name } == ["read", "write", "edit", "bash"])
    #expect(snapshot.sections().map { $0.section.key } == [
        "preamble", "tools", "rules", "docs", "project_context", "skills", "cwd",
    ])
    #expect(snapshot.installed().allSatisfy { $0.hooks.isEmpty && $0.wraps.isEmpty && $0.tasks.isEmpty })
}

@Test func codingRegistryCreatesIndependentRegistries() throws {
    let settings = SettingsManager.inMemory()
    let first = try createCodingRegistry(settingsManager: settings, cwd: "/first")
    let second = try createCodingRegistry(settingsManager: settings, cwd: "/second")
    first.uninstall(name: "pi-prompt")
    #expect(first.snapshot().installed().map(\.name) == ["coding-tools"])
    #expect(second.snapshot().installed().map(\.name) == ["coding-tools", "pi-prompt"])
}
