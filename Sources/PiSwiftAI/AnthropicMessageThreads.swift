import Foundation
import Synchronization

/// A continuation is a single-use server reply. The generation also prevents a reply
/// received after session cleanup from restoring a disposed session's state.
struct AnthropicThreadRequest: Sendable {
    let sessionId: String
    let generation: UUID
    let body: Data
}

private struct AnthropicThreadEntry: Sendable {
    let prefixCount: Int
    let prefixHash: String
    let replyId: String
}

private enum AnthropicThreadValue: Sendable {
    case pending
    case ready(AnthropicThreadEntry)
    case off
}

private struct AnthropicThreadSlot: Sendable {
    let generation: UUID
    var value: AnthropicThreadValue
}

private struct AnthropicThreadStorage: Sendable {
    var slots: [String: AnthropicThreadSlot] = [:]
    var order: [String] = []
}

final class AnthropicMessageThreadStore: Sendable {
    static let shared = AnthropicMessageThreadStore()
    private let storage = Mutex(AnthropicThreadStorage())
    private let limit = 10_000

    init(registerForCleanup: Bool = true) {
        if registerForCleanup {
            _ = registerSessionResourceCleanup { [weak self] sessionId in
                self?.cleanup(sessionId)
            }
        }
    }

    private func cleanup(_ sessionId: String?) {
        storage.withLock { state in
            if let sessionId, !sessionId.isEmpty {
                state.slots.removeValue(forKey: sessionId)
                state.order.removeAll { $0 == sessionId }
            } else {
                state.slots.removeAll()
                state.order.removeAll()
            }
        }
    }

    func reset() { cleanup(nil) }
    func storedSessionCount() -> Int { storage.withLock { $0.slots.count } }

    private func touch(_ sessionId: String, state: inout AnthropicThreadStorage) {
        state.order.removeAll { $0 == sessionId }
        state.order.append(sessionId)
        if state.order.count > limit {
            let oldest = state.order.removeFirst()
            state.slots.removeValue(forKey: oldest)
        }
    }

    func prepare(model: Model, sessionId: String, fullBody: Data, betas: [String]?) throws -> AnthropicThreadRequest? {
        guard var body = try JSONSerialization.jsonObject(with: fullBody) as? [String: Any],
              let messages = body["messages"] as? [[String: Any]] else { return nil }
        let prepared: (UUID, AnthropicThreadEntry?)? = storage.withLock { state in
            if let slot = state.slots[sessionId] {
                switch slot.value {
                case .off: return nil
                case .pending: return (slot.generation, nil)
                case .ready(let entry):
                    if messages.count > entry.prefixCount,
                       let hash = try? anthropicThreadPrefixHash(model: model, body: body, betas: betas,
                           messages: Array(messages.prefix(entry.prefixCount))), hash == entry.prefixHash {
                        state.slots[sessionId]?.value = .pending
                        return (slot.generation, entry)
                    }
                    return (slot.generation, nil)
                }
            }
            let generation = UUID()
            state.slots[sessionId] = AnthropicThreadSlot(generation: generation, value: .pending)
            touch(sessionId, state: &state)
            return (generation, nil)
        }
        guard let (generation, continuation) = prepared else { return nil }
        if let continuation {
            body["messages"] = Array(messages.dropFirst(continuation.prefixCount))
            body.removeValue(forKey: "system")
            body.removeValue(forKey: "tools")
            body["thread"] = ["type": "continue", "previous_message_id": continuation.replyId]
        } else {
            body["thread"] = ["type": "create"]
        }
        return AnthropicThreadRequest(sessionId: sessionId, generation: generation,
            body: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]))
    }

    func create(fullBody: Data, from request: AnthropicThreadRequest) throws -> AnthropicThreadRequest {
        var body = try JSONSerialization.jsonObject(with: fullBody) as? [String: Any] ?? [:]
        body["thread"] = ["type": "create"]
        return AnthropicThreadRequest(sessionId: request.sessionId, generation: request.generation,
            body: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]))
    }

    func turnOff(_ request: AnthropicThreadRequest) {
        storage.withLock { state in
            guard state.slots[request.sessionId]?.generation == request.generation else { return }
            state.slots[request.sessionId]?.value = .off
            touch(request.sessionId, state: &state)
        }
    }

    func record(_ request: AnthropicThreadRequest, model: Model, fullBody: Data, betas: [String]?,
                reply: [String: Any], replyId: String) throws {
        guard let body = try JSONSerialization.jsonObject(with: fullBody) as? [String: Any],
              let messages = body["messages"] as? [[String: Any]] else { return }
        let prefix = messages + [reply]
        let hash = try anthropicThreadPrefixHash(model: model, body: body, betas: betas, messages: prefix)
        storage.withLock { state in
            guard state.slots[request.sessionId]?.generation == request.generation else { return }
            state.slots[request.sessionId]?.value = .ready(AnthropicThreadEntry(
                prefixCount: prefix.count, prefixHash: hash, replyId: replyId))
            touch(request.sessionId, state: &state)
        }
    }
}

private func normalizedAnthropicThreadMessage(_ value: Any) -> Any {
    if let object = value as? [String: Any] {
        var result: [String: Any] = [:]
        for (key, child) in object where key != "cache_control" {
            if key == "content", let text = child as? String {
                result[key] = [["type": "text", "text": text]]
            } else {
                result[key] = normalizedAnthropicThreadMessage(child)
            }
        }
        return result
    }
    if let array = value as? [Any] { return array.map(normalizedAnthropicThreadMessage) }
    return value
}

private func anthropicThreadPrefixHash(model: Model, body: [String: Any], betas: [String]?, messages: [[String: Any]]) throws -> String {
    let fixed: [Any] = [model.provider, model.baseUrl, body["model"] ?? NSNull(), body["system"] ?? NSNull(),
        body["tools"] ?? NSNull(), body["thinking"] ?? NSNull(), body["output_config"] ?? NSNull(),
        body["tool_choice"] ?? NSNull(), betas as Any? ?? NSNull(), body["fallbacks"] ?? NSNull()]
    let settings = try JSONSerialization.data(withJSONObject: fixed, options: [.sortedKeys, .fragmentsAllowed])
    let conversation = try JSONSerialization.data(withJSONObject: messages.map(normalizedAnthropicThreadMessage),
        options: [.sortedKeys, .fragmentsAllowed])
    return shortHash(String(decoding: settings + conversation, as: UTF8.self))
}

struct AnthropicThreadRejection: Sendable {
    let startNew: Bool
    let reason: String
    let message: String
}

func anthropicThreadRejection(_ error: Error) -> AnthropicThreadRejection? {
    guard case StreamError.providerRequest(let status, _, let message) = error else { return nil }
    let body = (try? JSONSerialization.jsonObject(with: Data(message.utf8))) as? [String: Any]
    let detail = body?["error"] as? [String: Any]
    let code = (detail?["details"] as? [String: Any])?["error_code"] as? String
    let text = detail?["message"] as? String ?? message
    let newThreadCodes: Set<String> = ["thread_not_found", "thread_already_continued",
        "thread_continue_in_flight", "thread_fingerprint_mismatch"]
    if let code, newThreadCodes.contains(code) {
        return AnthropicThreadRejection(startNew: true, reason: code, message: text)
    }
    if code == "thread_unsupported_request" || (code == nil && status == 400 && text.contains("thread")) {
        return AnthropicThreadRejection(startNew: false, reason: code ?? String(status ?? 400), message: text)
    }
    return nil
}
