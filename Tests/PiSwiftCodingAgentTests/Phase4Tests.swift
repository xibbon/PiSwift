import Foundation
import Testing
import PiSwiftCodingAgent
import PiSwiftAI

// Phase 4 tests cover PiSwiftCodingAgent changes ported from pi-mono v0.61.1 → v0.70.5.

// MARK: - SettingsManager additions (v0.68.1, v0.70.0, v0.70.3)

/// v0.68.1: terminal.imageWidthCells default and round-trip.
@Test func settingsManagerImageWidthCells() throws {
    let dir = makeTempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let mgr = SettingsManager.create(dir, dir)

    // Default is 60.
    #expect(mgr.getImageWidthCells() == 60)

    mgr.setImageWidthCells(120)
    #expect(mgr.getImageWidthCells() == 120)

    // Persist + reload.
    let mgr2 = SettingsManager.create(dir, dir)
    #expect(mgr2.getImageWidthCells() == 120)
}

/// v0.70.0: terminal.showTerminalProgress is opt-in. Default false.
@Test func settingsManagerShowTerminalProgress() throws {
    let dir = makeTempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let mgr = SettingsManager.create(dir, dir)

    #expect(mgr.getShowTerminalProgress() == false)

    mgr.setShowTerminalProgress(true)
    #expect(mgr.getShowTerminalProgress() == true)
}

/// v0.70.3: warnings.anthropicExtraUsage opt-out.
@Test func settingsManagerAnthropicExtraUsageWarning() throws {
    let dir = makeTempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let mgr = SettingsManager.create(dir, dir)

    // Default: warning enabled.
    #expect(mgr.getAnthropicExtraUsageWarning() == true)

    mgr.setAnthropicExtraUsageWarning(false)
    #expect(mgr.getAnthropicExtraUsageWarning() == false)

    // Persist + reload.
    let mgr2 = SettingsManager.create(dir, dir)
    #expect(mgr2.getAnthropicExtraUsageWarning() == false)
}

/// v0.67.1: install telemetry can be disabled via setting OR PI_OFFLINE / PI_TELEMETRY env vars.
@Test func settingsManagerInstallTelemetry() throws {
    let dir = makeTempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let mgr = SettingsManager.create(dir, dir)

    // Default true (when env vars not set).
    #expect(mgr.getInstallTelemetryEnabled() == true)

    mgr.setInstallTelemetryEnabled(false)
    #expect(mgr.getInstallTelemetryEnabled() == false)
}

/// v0.63.0 / v0.68.1: sessionDir setting round-trip + tilde expansion at resolution time.
@Test func settingsManagerSessionDir() throws {
    let dir = makeTempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let mgr = SettingsManager.create(dir, dir)

    #expect(mgr.getSessionDir() == nil)

    mgr.setSessionDir("~/sessions")
    #expect(mgr.getSessionDir() == "~/sessions")
}

/// v0.68.1: sessionDir with `~` expands to home directory at resolution time.
@Test func defaultSessionDirExpandsTilde() {
    let cwd = makeTempDir()
    defer { try? FileManager.default.removeItem(atPath: cwd) }

    let resolved = getDefaultSessionDir(cwd: cwd, sessionDir: "~/test-pi-sessions-\(UUID().uuidString)")
    #expect(!resolved.hasPrefix("~"))
    #expect(resolved.contains(NSHomeDirectory()) || resolved.hasPrefix("/"))
    // Cleanup the directory we created.
    try? FileManager.default.removeItem(atPath: resolved)
}

// MARK: - Args additions

/// v0.67.2: multiple --append-system-prompt values join with \n\n.
@Test func argsAppendSystemPromptJoinsMultipleValues() {
    var args = Args()
    args.appendSystemPrompts = ["first", "second", "third"]
    #expect(args.appendSystemPrompt == "first\n\nsecond\n\nthird")
}

@Test func argsAppendSystemPromptNilWhenEmpty() {
    var args = Args()
    args.appendSystemPrompts = []
    #expect(args.appendSystemPrompt == nil)

    args.appendSystemPrompts = nil
    #expect(args.appendSystemPrompt == nil)
}

/// v0.67.4 / v0.68.0 / v0.70.0: new flags exist on Args.
@Test func argsHasNewFlags() {
    var args = Args()
    args.noContextFiles = true
    args.noBuiltinTools = true
    #expect(args.noContextFiles == true)
    #expect(args.noBuiltinTools == true)
}

// MARK: - Skill discovery boundary (v0.63.1)

/// v0.63.1: when a directory contains SKILL.md, treat the entire directory as a single skill
/// and don't recurse into subdirectories looking for nested SKILL.md.
@Test func skillsDoNotRecurseIntoSkillMdSubtrees() throws {
    let root = makeTempDir()
    defer { try? FileManager.default.removeItem(atPath: root) }

    // Top-level SKILL.md → this dir IS a skill.
    let outerSkill = "\(root)/outer"
    try FileManager.default.createDirectory(atPath: outerSkill, withIntermediateDirectories: true)
    try """
    ---
    name: outer
    description: Outer skill
    ---
    Outer skill content.
    """.write(toFile: "\(outerSkill)/SKILL.md", atomically: true, encoding: .utf8)

    // Nested subdirectory ALSO has a SKILL.md — must NOT be picked up as a separate skill.
    let nested = "\(outerSkill)/nested"
    try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)
    try """
    ---
    name: nested
    description: Nested skill
    ---
    Should not be loaded.
    """.write(toFile: "\(nested)/SKILL.md", atomically: true, encoding: .utf8)

    let result = loadSkillsFromDir(options: LoadSkillsFromDirOptions(dir: root, source: "test"))
    let names = result.skills.map { $0.name }
    #expect(names.contains("outer"))
    #expect(!names.contains("nested"))
}

// MARK: - Helpers

private func makeTempDir() -> String {
    let dir = NSTemporaryDirectory() + "phase4-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}
