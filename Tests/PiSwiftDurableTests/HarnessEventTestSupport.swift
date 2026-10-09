import Foundation
import Synchronization
import Testing
import PiSwiftAI
import PiSwiftChord
@testable import PiSwiftDurable
import PiSwiftDurableTesting

final class HarnessEventLog: Sendable {
    private let state = Mutex<[[JSONValue]]>([])
    var batches: [[JSONValue]] { state.withLock { $0 } }
    var events: [JSONValue] { batches.flatMap { $0 } }
    var types: [String] { events.compactMap { $0["type"]?.stringValue } }
    func append(_ events: [DurableAgentEvent]) throws {
        let json = try events.map { try JSONValue(encoding: $0) }
        state.withLock { $0.append(json) }
    }
    func start(_ stream: DurableAgentEventWatch) throws { try stream.start { [self] events, _ in try append(events) } }
    func waitForType(_ type: String, count: Int = 1) async throws {
        try await eventually { self.types.filter { $0 == type }.count >= count }
    }
    func waitForBatches(_ count: Int) async throws { try await eventually { self.batches.count >= count } }
    func waitForDone(_ id: SubmissionID) async throws {
        try await eventually { self.events.contains { $0["type"] == "submission" && $0["record"]?["id"] == .number(Double(id.rawValue)) && $0["record"]?["status"] == "done" } }
    }
}
func eventListen(_ opened: OpenChatResult) async throws -> (DurableAgentEventWatch, HarnessEventLog) {
    let stream = try await opened.harness.watchEvents(conversationId: opened.root.id, context: .background)
    let log = HarnessEventLog(); try log.start(stream); return (stream, log)
}
func eventLiveChange(_ opened: OpenChatResult, _ edit: @escaping @Sendable (JSONDraft) throws -> Void) async throws {
    try await opened.root.commit({ tx in try edit(await tx.doc(LiveDoc, conversationId: opened.root.id)) }, context: .background)
}
func eventPartial(_ text: String) throws -> JSONObject { try EntryRecord.encodeMessages([.assistant(chatAssistant(text))])[0].objectValue! }
func eventCompactTypes(_ log: HarnessEventLog) -> [String] {
    log.types.enumerated().compactMap { index, value in index == 0 || log.types[index - 1] != value ? value : nil }
}
func eventRebuild(_ initial: JSONValue, changes: [JSONValue]) throws -> JSONValue {
    var message = initial
    for change in changes {
        let type = change["type"]?.stringValue ?? ""
        if type == "message" { message = change["message"]!; continue }
        let index = change["contentIndex"]!.intValue!
        var blocks = message["content"]!.arrayValue!
        if type == "block" { blocks[index] = change["block"]! }
        else if type.hasSuffix("_start") { blocks.insert(change["block"]!, at: index) }
        else {
            var block = blocks[index].objectValue!
            if type == "text_delta" || type == "thinking_delta" {
                let key = type == "text_delta" ? "text" : "thinking"
                block[key] = .string((block[key]?.stringValue ?? "") + change["delta"]!.stringValue!)
            } else if type == "toolcall_delta" {
                let path = try change["path"]!.arrayValue!.map { value -> Delta.PathSegment in
                    if let key = value.stringValue { return .key(key) }; return .index(try #require(value.intValue))
                }
                block["arguments"] = try Delta.applyImmutable(block["arguments"]!, [.append(path, change["delta"]!.stringValue!)])
            }
            blocks[index] = .object(block)
        }
        var object = message.objectValue!; object["content"] = .array(blocks); message = .object(object)
    }
    return message
}
