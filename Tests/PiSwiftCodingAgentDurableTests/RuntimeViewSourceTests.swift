import Foundation
import PiSwiftChord
@testable import PiSwiftCodingAgentDurable
import PiSwiftDurable
import Synchronization
import Testing

private final class ViewScheduler: Sendable {
    private let callbacks = Mutex<[@Sendable () -> Void]>([])
    var count: Int { callbacks.withLock { $0.count } }
    func schedule(_ callback: @escaping @Sendable () -> Void) { callbacks.withLock { $0.append(callback) } }
    func run() {
        let batch = callbacks.withLock { callbacks in
            let batch = callbacks
            callbacks.removeAll()
            return batch
        }
        for callback in batch { callback() }
    }
}

private func runtimeView() -> DurableView {
    DurableView(session: .init(id: "session", directory: "/session", cwd: "/project"),
                conversation: .init(conversation: .init(id: rootConversationID), entries: [], docs: [:]),
                conversations: [.init(id: rootConversationID, label: "main")], models: [])
}

@Test func runtimeViewSourceCombinesChanges() {
    let scheduler = ViewScheduler()
    let source = RuntimeViewSource(runtimeView(), schedule: scheduler.schedule)
    let calls = Mutex(0)
    let subscription = source.subscribe { calls.withLock { $0 += 1 } }
    source.updateTasks(TaskGraph())
    source.notice(.info, "First")
    let conversation = ConversationView(conversation: .init(id: rootConversationID), entries: [],
                                        docs: ["pi.agent": ["cwd": .string("/other")]])
    source.updateConversation(conversation)
    #expect(scheduler.count == 1)
    #expect(calls.withLock { $0 } == 0)
    #expect(source.current().conversation == conversation)
    #expect(source.current().tasks == TaskGraph())
    scheduler.run()
    #expect(calls.withLock { $0 } == 1)
    source.updateTasks(nil)
    #expect(scheduler.count == 1)
    scheduler.run()
    #expect(calls.withLock { $0 } == 2)
    subscription.cancel()
}

@Test func runtimeViewSourceListenersCanReadSubscribeAndCancel() {
    let scheduler = ViewScheduler()
    let source = RuntimeViewSource(runtimeView(), schedule: scheduler.schedule)
    let subscription = Mutex<DurableViewSubscription?>(nil)
    let calls = Mutex<[String]>([])
    subscription.withLock { value in
        value = source.subscribe {
            #expect(source.current().notices.count == 1)
            calls.withLock { $0.append("first") }
            let added = source.subscribe { calls.withLock { $0.append("added") } }
            added.cancel()
            subscription.withLock { $0 }?.cancel()
        }
    }
    source.notice(.info, "First")
    scheduler.run()
    source.notice(.info, "Second")
    scheduler.run()
    #expect(calls.withLock { $0 } == ["first"])
}

@Test func runtimeViewSourceBoundsNoticesAndKeepsIDs() {
    let scheduler = ViewScheduler()
    let source = RuntimeViewSource(runtimeView(), schedule: scheduler.schedule)
    for index in 1...25 { source.notice(.info, "Notice \(index)") }
    #expect(source.current().notices.map(\.id) == Array(6...25))
    #expect(source.current().notices.first?.message == "Notice 6")
    #expect(scheduler.count == 1)
}

private struct ViewReportError: Error, LocalizedError {
    let text: String
    var errorDescription: String? { text }
}

@Test func runtimeReportsFlushInOrderAndFailuresAreErrors() {
    let scheduler = ViewScheduler()
    let source = RuntimeViewSource(runtimeView(), schedule: scheduler.schedule)
    let reports = RuntimeReports()
    reports.report(ViewReportError(text: "First"))
    reports.report(ViewReportError(text: "Second"))
    #expect(source.current().notices.isEmpty)
    reports.attach(source)
    reports.report(ViewReportError(text: "Third"))
    source.fail(ViewReportError(text: "Failure"))
    #expect(source.current().notices.map(\.message) == ["First", "Second", "Third", "Failure"])
    #expect(source.current().notices.map(\.level) == [.warning, .warning, .warning, .error])
    #expect(scheduler.count == 1)
}

@Test func runtimeTitleReadsStringsAndTextBlocks() throws {
    let id = try EntryID(3)
    func entry(_ message: JSONValue, kind: String = "pi.user") -> EntryRecord {
        EntryRecord(id: id, conversationId: rootConversationID, kind: kind, model: [message])
    }
    #expect(runtimeTitle(of: entry(.object(["role": .string("user"), "content": .string("  Read\n the\tfile.  ")]))) == "Read the file.")
    let blocks: JSONValue = .array([
        .object(["type": .string("text"), "text": .string(" Read\n")]),
        .object(["type": .string("image"), "text": .string("Ignore")]),
        .object(["type": .string("text"), "text": .string("the file. ")])
    ])
    #expect(runtimeTitle(of: entry(.object(["role": .string("user"), "content": blocks]))) == "Read the file.")
    #expect(runtimeTitle(of: entry(.object(["role": .string("assistant"), "content": .string("Ignore")]))) == nil)
    #expect(runtimeTitle(of: entry(.object(["role": .string("user"), "content": .string("Ignore")]), kind: "pi.assistant")) == nil)
    #expect(runtimeTitle(of: entry(.object(["role": .string("user"), "content": .array([])]))) == "")
}

@Test func runtimeViewSourceRecordsConversationAndFirstTitle() throws {
    let scheduler = ViewScheduler()
    let source = RuntimeViewSource(runtimeView(), schedule: scheduler.schedule)
    let child = try ConversationID(2)
    func entry(_ id: Int64, _ text: String) throws -> EntryRecord {
        EntryRecord(id: try EntryID(id), conversationId: child, kind: "pi.user",
                    model: [.object(["role": .string("user"), "content": .string(text)])])
    }
    source.record(.init(seq: try Seq(1), changes: [
        .conversation(.init(id: child)), .entry(try entry(3, "  Read\nfile. ")),
        .entry(try entry(4, "Second title"))
    ]))
    #expect(source.current().conversations == [
        .init(id: rootConversationID, label: "main"),
        .init(id: child, label: "subagent 2", title: "Read file.")
    ])
    #expect(scheduler.count == 1)
}

@Test func runtimeViewSourceFinishDropsPendingAndFutureNotifications() {
    let scheduler = ViewScheduler()
    let source = RuntimeViewSource(runtimeView(), schedule: scheduler.schedule)
    let calls = Mutex(0)
    let subscription = source.subscribe { calls.withLock { $0 += 1 } }
    source.notice(.info, "Before")
    source.finish()
    scheduler.run()
    source.notice(.info, "After")
    source.updateTasks(TaskGraph())
    let later = source.subscribe { calls.withLock { $0 += 1 } }
    #expect(calls.withLock { $0 } == 0)
    #expect(scheduler.count == 0)
    #expect(source.current().notices.map(\.message) == ["Before"])
    subscription.cancel()
    later.cancel()
}

@Test func runtimeTitleUsesJavaScriptWhitespace() throws {
    let entry = EntryRecord(id: try EntryID(2), conversationId: rootConversationID, kind: "pi.user",
                            model: [.object(["role": .string("user"),
                                             "content": .string("\u{FEFF}Read\u{00A0}the\u{2028}file.\u{0085}Keep\u{200B}this\u{FEFF}")])])
    #expect(runtimeTitle(of: entry) == "Read the file.\u{0085}Keep\u{200B}this")
}
