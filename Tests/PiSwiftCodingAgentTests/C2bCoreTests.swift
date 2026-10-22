import Foundation
import Testing
import PiSwiftAI
@testable import PiSwiftCodingAgent

@Test(arguments: [ClipboardPlatform.macOS, .windows, .linux])
func c2bForcedOSC52FollowsSuccessfulCopy(platform: ClipboardPlatform) {
    let events = LockedState<[String]>([])
    let backend = ClipboardBackend(nativeCopy: { text in
        events.withLock { $0.append("native:" + text) }
        return true
    }, nativeRead: { .unavailable }, command: { name, _, text in
        events.withLock { $0.append(name + ":" + (text ?? "")) }
        return .content("")
    }, emitOSC52: { text in
        events.withLock { $0.append("osc52:" + text) }
        return true
    })
    let result = copyToClipboard("hello", platform: platform,
        environment: ["PI_CLIPBOARD_OSC52": "1", "DISPLAY": ":99"], backend: backend)
    #expect(result == .success)
    #expect(events.withLock { $0 } == [platform == .linux ? "xclip:hello" : "native:hello", "osc52:hello"])
}

@Test(arguments: ["", "0", "true", "01", " 1"])
func c2bOSC52RequiresExactOptIn(flag: String) {
    let events = LockedState<[String]>([])
    let backend = ClipboardBackend(nativeCopy: { _ in true }, nativeRead: { .unavailable },
        command: { _, _, _ in .unavailable }, emitOSC52: { _ in
            events.withLock { $0.append("osc52") }
            return true
        })
    #expect(copyToClipboard("hello", platform: .macOS, environment: ["PI_CLIPBOARD_OSC52": flag], backend: backend) == .success)
    #expect(events.withLock { $0.isEmpty })
}

@Test func c2bForcedOSC52KeepsUnverifiedFailureAndDuplicateRules() {
    let writes = LockedState(0)
    let accepted = ClipboardBackend(nativeCopy: { _ in false }, nativeRead: { .unavailable },
        command: { _, _, _ in .unavailable }, emitOSC52: { _ in
            writes.withLock { $0 += 1 }
            return true
        })
    #expect(copyToClipboard("hello", platform: .linux,
        environment: ["PI_CLIPBOARD_OSC52": "1", "SSH_CONNECTION": "remote",
                      "WSL_DISTRO_NAME": "Ubuntu", "WT_SESSION": "terminal"], backend: accepted) == .osc52SentUnverified)
    #expect(writes.withLock { $0 } == 1)
    let rejected = ClipboardBackend(nativeCopy: { _ in false }, nativeRead: { .unavailable },
        command: { _, _, _ in .unavailable }, emitOSC52: { _ in false })
    #expect(copyToClipboard("hello", platform: .macOS,
        environment: ["PI_CLIPBOARD_OSC52": "1"], backend: rejected) ==
        .failure("Clipboard unavailable: text exceeds the OSC 52 size limit"))
}

@Test(arguments: SessionShareDestination.allCases)
func c2bShareDestinationFileRoundTrip(destination: SessionShareDestination) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("c2b-settings-\(UUID().uuidString)")
    let agent = root.appendingPathComponent("agent")
    try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = agent.appendingPathComponent("settings.json")
    try Data("{\"sessionShareDestination\":\"\(destination.rawValue)\"}".utf8).write(to: path)
    let loaded = SettingsManager.create(root.path, agent.path)
    #expect(loaded.getSessionShareDestination() == destination)
    #expect(loaded.getSettings().sessionShareDestination == destination)
    #expect(loaded.settingsJSONForDiagnostics(loaded.getSettings())["sessionShareDestination"] == AnyCodable(destination.rawValue))
    loaded.setSessionShareDestination(.auto)
    loaded.setSessionShareDestination(destination)
    await loaded.flush()
    let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
    #expect(saved["sessionShareDestination"] as? String == destination.rawValue)
    #expect(SettingsManager.create(root.path, agent.path).getSessionShareDestination() == destination)
    await loaded.reload()
    #expect(loaded.getSessionShareDestination() == destination)
    #expect(loaded.drainErrors().isEmpty)
}

@Test func c2bShareDestinationDefaultsMergesAndDiagnostics() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("c2b-merge-\(UUID().uuidString)")
    let agent = root.appendingPathComponent("agent")
    let project = root.appendingPathComponent(CONFIG_DIR_NAME)
    try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(SettingsManager.inMemory().getSessionShareDestination() == .auto)
    let globalPath = agent.appendingPathComponent("settings.json")
    let projectPath = project.appendingPathComponent("settings.json")
    try Data(#"{"sessionShareDestination":"gist"}"#.utf8).write(to: globalPath)
    try Data(#"{"sessionShareDestination":"radius"}"#.utf8).write(to: projectPath)
    let loaded = SettingsManager.create(root.path, agent.path)
    #expect(loaded.getSessionShareDestination() == .radius)
    #expect(loaded.getGlobalSettings().sessionShareDestination == .gist)
    #expect(loaded.getProjectSettings().sessionShareDestination == .radius)
    #expect(SettingsManager.create(root.path, agent.path, projectTrusted: false).getSessionShareDestination() == .gist)
    var overrides = Settings()
    overrides.sessionShareDestination = .auto
    loaded.applyOverrides(overrides)
    #expect(loaded.getSessionShareDestination() == .auto)
    for invalid in [#""unknown""#, "42", "null"] {
        try Data("{\"sessionShareDestination\":\(invalid)}".utf8).write(to: projectPath)
        #expect(SettingsManager.create(root.path, agent.path).getSessionShareDestination() == .auto)
        try Data("{\"sessionShareDestination\":\(invalid)}".utf8).write(to: globalPath)
        #expect(SettingsManager.create(root.path, agent.path, projectTrusted: false).getSessionShareDestination() == .auto)
    }
}

@Test(arguments: [SessionShareDestination.auto, .gist])
@MainActor func c2bShareUsesGistWithoutRadiusLookup(destination: SessionShareDestination) async throws {
    var settings = Settings()
    settings.sessionShareDestination = destination
    var calls = 0
    let url = try await shareSession(settingsManager: .inMemory(settings)) {
        // No provider or authentication lookup is needed by the core route.
        calls += 1
        return "https://gist.github.com/test/shared"
    }
    #expect(calls == 1)
    #expect(url == "https://gist.github.com/test/shared")
}

@Test @MainActor func c2bForcedRadiusStopsBeforeGistWork() async {
    var settings = Settings()
    settings.sessionShareDestination = .radius
    var calls = 0
    do {
        _ = try await shareSession(settingsManager: .inMemory(settings)) {
            calls += 1
            return "uploaded"
        }
        Issue.record("Forced Radius must stop sharing")
    } catch {
        #expect(error as? SessionShareError == .radiusUnavailable)
        #expect(error.localizedDescription == "Radius sharing is not available in this version.")
        #expect(!error.localizedDescription.contains("/login radius"))
    }
    #expect(calls == 0)
}

@Test func c2bReadLineRangeUsesAllUpstreamVectors() {
    let cases: [(AnyCodable?, AnyCodable?, String)] = [
        (AnyCodable(25), AnyCodable(13), ":25-37"),
        (AnyCodable("25"), AnyCodable("13"), ":25-37"),
        (AnyCodable(NSNull()), AnyCodable("13"), ":1-13"),
        (AnyCodable("25"), AnyCodable(NSNull()), ":25"),
        (nil, nil, ""),
        (AnyCodable("abc"), AnyCodable(13), ""),
        (AnyCodable(25), AnyCodable(""), ""),
        (AnyCodable(25), AnyCodable("Infinity"), "")
    ]
    for (offset, limit, expected) in cases {
        #expect(formatReadLineRange(offset: offset, limit: limit) == expected)
    }
}

@Test func c2bReadLineRangePreservesNumericDisplayRules() {
    let cases: [(Any, Any, String)] = [
        (" 25 ", "\t13\n", ":25-37"), (NSNull(), NSNull(), ""),
        (1, 0, ":1"), (0, 1, ":0"), (-2, 2, ":-2--1"), (1.5, 2.5, ":1.5-3"),
        ("0x19", "0b1101", ":25-37"), ("0o31", "0X0d", ":25-37"),
        ("\u{FEFF}2.5e1", "+13.", ":25-37"),
        (1e20, NSNull(), ":100000000000000000000"), (1e21, NSNull(), ":1e+21"),
        (1e-6, NSNull(), ":0.000001"), (1e-7, NSNull(), ":1e-7"), (-0.0, NSNull(), ":0"),
        (Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude, ":1.7976931348623157e+308-Infinity"),
        (true, 13, ""), (25, false, ""), ([25], 13, ""), (25, ["n": 13], ""),
        (" ", 13, ""), (25, "NaN", ""), (Double.infinity, 13, ""), (25, Double.nan, ""),
        ("0x1p2", 13, ""), ("+0x19", 13, ""), ("2_5", 13, ""), ("25px", 13, "")
    ]
    for (offset, limit, expected) in cases {
        #expect(formatReadLineRange(offset: AnyCodable(offset), limit: AnyCodable(limit)) == expected)
    }
    #expect(formatReadLineRange(offset: nil, limit: AnyCodable(13)) == ":1-13")
    #expect(formatReadLineRange(offset: AnyCodable(25), limit: nil) == ":25")
}
