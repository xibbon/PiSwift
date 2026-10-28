import Foundation
import PiSwiftCodingAgent
import PiSwiftCodingAgentDurable
import PiSwiftDurable
import PiSwiftChord
import Testing

@Suite struct E3HarnessSettingsTests {
    @Test func overrideMapReachesDurablePolicyWithoutResolvingOneModelEarly() {
        var source = PiSwiftCodingAgent.Settings()
        source.compaction = .init(enabled: false, reserveTokens: 100, keepRecentTokens: 200, modelOverrides: [
            "faux/one": .init(reserveTokens: 0), "faux/two": .init(keepRecentTokens: 50)
        ])
        let value = harnessSettings(from: .inMemory(source)).resolve()
        #expect(value.compaction.modelOverrides == ["faux/one": .init(reserveTokens: 0), "faux/two": .init(keepRecentTokens: 50)])
        #expect(compactionPolicy(settings: value, model: .init(provider: "faux", modelId: "one")) ==
            .init(enabled: false, reserveTokens: 0, keepRecentTokens: 200))
        #expect(compactionPolicy(settings: value, model: .init(provider: "faux", modelId: "two")) ==
            .init(enabled: false, reserveTokens: 100, keepRecentTokens: 50))
    }

    @Test func maintainedHostKeepsQueuedInputsByDefault() {
        // Runtime.swift uses this adapter without a policy argument, as pi durable requires (DQ5 a).
        #expect(harnessSettings(from: .inMemory()).resolve().afterFailedRun == .keep)
        #expect(resolveSettings().afterFailedRun == .keep)
    }

    @Test(arguments: AfterFailedRun.allCases)
    func customHarnessHostsCanSelectThePolicy(_ policy: AfterFailedRun) throws {
        #expect(harnessSettings(from: .inMemory(), afterFailedRun: policy).resolve().afterFailedRun == policy)
        #expect(try JSONValue(encoding: policy).decode(AfterFailedRun.self) == policy)
        #expect(AfterFailedRun(rawValue: "invalid") == nil)
        #expect(throws: DecodingError.self) { try JSONValue.string("invalid").decode(AfterFailedRun.self) }
    }

    @Test func overrideMapReadsReloadedSettings() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("e3-settings-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        try Data(#"{"compaction":{"modelOverrides":{"faux/one":{"reserveTokens":100}}}}"#.utf8).write(to: file)
        let manager = SettingsManager.create(directory.path, directory.path)
        let provider = harnessSettings(from: manager)
        #expect(provider.resolve().compaction.modelOverrides?["faux/one"]?.reserveTokens == 100)
        try Data(#"{"compaction":{"modelOverrides":{"faux/two":{"keepRecentTokens":50}}}}"#.utf8).write(to: file)
        await manager.reload()
        #expect(manager.drainErrors().isEmpty)
        #expect(provider.resolve().compaction.modelOverrides == ["faux/two": .init(keepRecentTokens: 50)])
    }
}
