import Foundation
import Synchronization
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

private struct ViewExampleEvidence: Decodable {
    struct Example: Decodable {
        let name: String
        let stdout: String
        let lines: [String]
        let calls: [[JSONValue]]
    }
    let tag: String
    let examples: [Example]
    static func load(_ name: String) throws -> Example {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Scripts/durable-fixtures/view-examples-v152.json")
        let evidence = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        #expect(evidence.tag == "v1.5.2")
        return try #require(evidence.examples.first { $0.name == name })
    }
}

private func viewExampleCheckLines(_ actual: [String], _ expected: ViewExampleEvidence.Example) {
    #expect(actual.count == expected.lines.count, "\(expected.name): stdout line count")
    for (index, pair) in zip(actual, expected.lines).enumerated() {
        #expect(pair.0 == pair.1, "\(expected.name): stdout line \(index + 1)")
    }
    #expect(actual.joined(separator: "\n") + "\n" == expected.stdout)
}

private func viewExampleLabel(_ label: String) -> String { label + String(repeating: " ", count: max(0, 28 - label.count)) }

/// The render function from tagged example 31. It uses entry data, not allocated IDs.
private func transcriptExampleRender(_ label: String, _ view: TranscriptView) throws -> String {
    var rows: [String] = []
    var run: (Int, Int)?
    func flush() {
        if let run { rows.append(run.0 == run.1 ? "\(run.0)" : "\(run.0)..\(run.1)") }
        run = nil
    }
    for item in view.items {
        if case .entry(let entry) = item {
            let data = try #require(entry.data?.stringValue)
            let line = try #require(Int(data.dropFirst("line ".count)))
            run = (run?.0 ?? line, line)
            continue
        }
        flush()
        let marker = if case .gap = item { "[load more]" } else { "[load earlier]" }
        rows.append(marker)
    }
    flush()
    return "\(viewExampleLabel(label)) \(rows.joined(separator: " "))"
}

private func transcriptExampleGap(_ view: TranscriptView) -> TranscriptGap? {
    view.items.compactMap { if case .gap(let gap) = $0 { gap } else { nil } }.first
}

/// This adapter projects Durable observer values for the available part of example 36.
/// It maps entry splices to kind splices. It does not implement Chord follow or derive.
private final class ViewExampleProjection: Sendable {
    private struct State {
        var kinds: [String] = []
        var tasks = 0
        var lines: [String] = []
        var calls: [[JSONValue]] = []
        var entryCommits = 0
        var graphFrames = 0
    }
    private let state = Mutex(State())
    private func nodeArray(_ values: [String]) -> String { "[ " + values.map { "'\($0)'" }.joined(separator: ", ") + " ]" }
    func initialize(_ value: ConversationView, _ graph: TaskGraph) {
        state.withLock { $0.kinds = value.entries.map(\.kind); $0.tasks = graph.tasks.count }
    }
    func conversation(_ call: WatchCall<ConversationView>) throws {
        guard case .value(let value, let ops, _) = call else { Issue.record("Unexpected observer failure"); return }
        try state.withLock { state in
            let kinds = value.entries.map(\.kind)
            guard kinds != state.kinds else { return }
            let projected: [Delta.Op] = try ops.compactMap { op in
                guard case .splice([.key("entries")], let index, let remove, let items) = op else { return nil }
                let values = try items.map { try #require($0.objectValue?["kind"]) }
                return .splice(["kinds"], index: index, remove: remove, items: values)
            }
            let encoded = try JSONValue.array(projected.map(\.json)).jsonText()
            state.kinds = kinds
            state.lines.append("frame: \(nodeArray(kinds)) \(encoded)")
            state.calls.append(["frame:", .array(kinds.map(JSONValue.string)), .string(encoded)])
        }
    }
    func graph(_ call: WatchCall<TaskGraph>) {
        guard case .value(let value, _, _) = call else { Issue.record("Unexpected graph failure"); return }
        state.withLock { $0.tasks = value.tasks.count; $0.graphFrames += 1 }
    }
    func commit(_ publication: CommitPublication) {
        if publication.changes.contains(where: { if case .entry = $0 { true } else { false } }) {
            state.withLock { $0.entryCommits += 1 }
        }
    }
    func finish() -> (lines: [String], calls: [[JSONValue]], entryCommits: Int, graphFrames: Int) {
        state.withLock { state in
            let line = "member value: { kinds: \(nodeArray(state.kinds)), tasks: \(state.tasks) }"
            let call: [JSONValue] = ["member value:", ["kinds": .array(state.kinds.map(JSONValue.string)), "tasks": .number(Double(state.tasks))]]
            return (state.lines + [line], state.calls + [call], state.entryCommits, state.graphFrames)
        }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct WindowTranscriptExampleV152Tests {
    @Test func example31TranscriptMatchesEveryTaggedOutputLine() async throws {
        let expected = try ViewExampleEvidence.load("31-transcript")
        let harness = try await Harness.open(storage: MemoryStorage(), options: .init(models: FakeDurableModels(), registry: createRegistry()), context: .background)
        let root = try await harness.root(context: .background)
        var count = 0
        func chat(_ n: Int) async throws {
            for _ in 0..<n {
                count += 1
                let line = count
                _ = try await root.commit({ tx in
                    try await tx.appendEntry(root.id, value: .init(kind: "chat", data: .string("line \(line)")))
                }, context: .background)
            }
        }
        var output: [String] = []
        try await chat(200)
        let transcript = try ConversationTranscript({ query, limit, context in
            try await root.entries(query: query, limit: limit, context: context)
        }, options: .init(pageSize: 20))
        var watch = try await root.watch(context: .background, window: .init(min: 10, max: 20))
        var view = try await transcript.merge(watch.value)
        output.append(try transcriptExampleRender("attach", view))
        try watch.start { call, _ in
            if case .value(let value, _, _) = call { _ = try await transcript.merge(value) }
        }
        // v1.5.2 D4: examples/31-transcript.ts:68–75 observes each live append.
        for _ in 0..<15 { try await chat(1); await watch.waitUntilIdle() }
        view = try await transcript.merge(watch.value)
        output.append(try transcriptExampleRender("15 more, live", view))
        view = try await transcript.loadEarlier(context: .background)
        output.append(try transcriptExampleRender("load earlier", view))
        _ = await watch.stop()
        try await chat(40)
        let resume40 = try #require(await transcript.resume)
        watch = try await root.watch(context: .background, window: .init(from: resume40.from, min: 10, max: 20))
        view = try await transcript.merge(watch.value)
        output.append(try transcriptExampleRender("resume after 40 missed", view))
        try watch.start { call, _ in
            if case .value(let value, _, _) = call { _ = try await transcript.merge(value) }
        }
        for _ in 0..<10 {
            guard let gap = transcriptExampleGap(view) else { break }
            view = try await transcript.fillGap(gap, context: .background)
            output.append(try transcriptExampleRender("fill gap", view))
        }
        #expect(transcriptExampleGap(view) == nil)
        _ = await watch.stop()
        try await chat(3)
        let resume3 = try #require(await transcript.resume)
        watch = try await root.watch(context: .background, window: .init(from: resume3.from, min: 10, max: 20))
        output.append("\(viewExampleLabel("resume after 3 missed")) window: \(watch.value.entries.count) entries")
        view = try await transcript.merge(watch.value)
        output.append(try transcriptExampleRender("", view))
        _ = await watch.stop()
        try await harness.close(context: .background)
        viewExampleCheckLines(output, expected)
        #expect(output.map { [JSONValue.string($0)] } == expected.calls)
    }

    @Test func example36ObserverProjectionMatchesTaggedValuesAndLines() async throws {
        // All three tagged lines are host member outputs. This test checks their
        // values and projected operations with Durable observers. Full host parity
        // needs Chord local/defineFacet/createHost/openStore/sqliteBackend,
        // self.open/follow/derive, member watches, and Durable StoreStorage.
        // It does not test host-store adoption, derive batching, or host close.
        let expected = try ViewExampleEvidence.load("36-durable-views")
        let storage = try await SqliteStorage.open(path: ":memory:")
        let harness = try await Harness.open(storage: storage, options: .init(models: FakeDurableModels(), registry: createRegistry()), context: .background)
        let root = try await harness.root(context: .background)
        let projection = ViewExampleProjection()
        let view = try await harness.observeConversation(root.id, observer: .init(advance: { call, _ in
            try projection.conversation(call)
        }, end: { _ in }), context: .background, window: .init(min: 50))
        let graph = try await harness.observeTaskGraph(.init(advance: { call, _ in
            projection.graph(call)
        }, end: { _ in }), context: .background)
        projection.initialize(view.value, graph.value)
        let commits = try harness.observeCommits(.init(advance: { publication, _ in
            projection.commit(publication)
        }, end: { _ in }))
        _ = try await root.submit(.write(entry: .init(kind: "example.first")), context: .background)
        _ = try await root.submit(.write(entry: .init(kind: "example.second")), context: .background)
        let result = projection.finish()
        #expect(result.entryCommits == 2)
        #expect(result.graphFrames == 0)
        viewExampleCheckLines(result.lines, expected)
        #expect(result.calls.count == expected.calls.count)
        for (index, pair) in zip(result.calls, expected.calls).enumerated() {
            #expect(pair.0 == pair.1, "36-durable-views: console call \(index + 1), observer projection")
        }
        view.detach(); graph.detach(); commits.detach()
        try await harness.close(context: .background)
    }
}
