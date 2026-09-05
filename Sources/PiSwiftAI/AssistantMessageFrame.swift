import Foundation

/// Compact progress for one assistant message. Persist terminal settlement separately.
public enum AssistantMessageFrame: Sendable {
    case start(partial: AssistantMessage)
    case textStart(contentIndex: Int, content: TextContent)
    case textDelta(contentIndex: Int, delta: String)
    case textEnd(contentIndex: Int, content: String, textSignature: String? = nil)
    case thinkingStart(contentIndex: Int, content: ThinkingContent)
    case thinkingDelta(contentIndex: Int, delta: String)
    case thinkingEnd(contentIndex: Int, content: String, thinkingSignature: String? = nil, redacted: Bool? = nil)
    case toolCallStart(contentIndex: Int, toolCall: ToolCall)
    case toolCallCheckpoint(contentIndex: Int, json: String)
    case toolCallDelta(contentIndex: Int, delta: String)
    case toolCallEnd(contentIndex: Int, toolCall: ToolCall)

    public var type: String {
        switch self {
        case .start: "start"
        case .textStart: "text_start"
        case .textDelta: "text_delta"
        case .textEnd: "text_end"
        case .thinkingStart: "thinking_start"
        case .thinkingDelta: "thinking_delta"
        case .thinkingEnd: "thinking_end"
        case .toolCallStart: "toolcall_start"
        case .toolCallCheckpoint: "toolcall_checkpoint"
        case .toolCallDelta: "toolcall_delta"
        case .toolCallEnd: "toolcall_end"
        }
    }

    fileprivate var index: Int? {
        switch self {
        case .start: nil
        case .textStart(let index, _), .textDelta(let index, _), .textEnd(let index, _, _),
             .thinkingStart(let index, _), .thinkingDelta(let index, _), .thinkingEnd(let index, _, _, _),
             .toolCallStart(let index, _), .toolCallCheckpoint(let index, _), .toolCallDelta(let index, _), .toolCallEnd(let index, _): index
        }
    }
}

public enum AssistantMessageFrameError: Error, LocalizedError, Sendable {
    case invalidFrame(String)
    public var errorDescription: String? { if case .invalidFrame(let message) = self { message } else { nil } }
}

private enum FrameBlockKind: String, Sendable { case text, thinking, toolCall }
private func frameBlockKind(_ block: ContentBlock) -> FrameBlockKind? {
    switch block { case .text: .text; case .thinking: .thinking; case .toolCall: .toolCall; case .image: nil }
}
private func checkFrameIndex(_ index: Int) throws {
    guard index >= 0, index <= 9_007_199_254_740_991 else {
        throw AssistantMessageFrameError.invalidFrame("Invalid assistant message frame contentIndex: \(index)")
    }
}

private func frameStartMessage(_ message: AssistantMessage) -> AssistantMessage {
    var result = message
    result.content = []
    result.stopReason = .pending
    result.errorMessage = nil
    result.rawStopReason = nil
    result.endTurn = nil
    result.deferred = nil
    return result
}

private struct FrameEncoderBlock: Sendable {
    var kind: FrameBlockKind
    var coveredChars = 0
    var deltaChars = 0
    var caughtUp = false
    var catchupJSON = ""
    var snapshotArguments: [String: AnyCodable] = [:]
}

private func frameJSONPrefix(_ snapshot: AnyCodable, _ current: AnyCodable) -> Bool {
    if let text = snapshot.value as? String { return (current.value as? String)?.hasPrefix(text) == true }
    if let values = snapshot.value as? [Any] {
        guard let other = current.value as? [Any], values.count <= other.count else { return false }
        return values.enumerated().allSatisfy { frameJSONPrefix(AnyCodable($0.element), AnyCodable(other[$0.offset])) }
    }
    if let values = snapshot.value as? [String: Any] {
        guard let other = current.value as? [String: Any] else { return false }
        return values.allSatisfy { key, value in other[key].map { frameJSONPrefix(AnyCodable(value), AnyCodable($0)) } ?? false }
    }
    return snapshot == current
}

/// A value-type encoder. Keep one instance for each assistant stream.
public struct AssistantMessageFrameEncoder: Sendable {
    private var started = false
    private var terminal = false
    private var blocks: [Int: FrameEncoderBlock] = [:]
    public init() {}

    public mutating func encode(_ event: AssistantMessageEvent) throws -> AssistantMessageFrame? {
        guard !terminal else { throw AssistantMessageFrameError.invalidFrame("Assistant message event follows a terminal event") }
        switch event {
        case .start(let partial):
            guard !started else { throw AssistantMessageFrameError.invalidFrame("Assistant message stream contains more than one start event") }
            started = true
            return .start(partial: frameStartMessage(partial))
        case .done:
            guard started else { throw AssistantMessageFrameError.invalidFrame("Assistant message done event appears before start") }
            terminal = true
            return nil
        case .error:
            terminal = true
            return nil
        default: break
        }
        guard started else { throw AssistantMessageFrameError.invalidFrame("Assistant message update event appears before start") }
        switch event {
        case .textStart(let index, let partial):
            guard case .text(let content) = try eventBlock(index, partial, .text) else { return nil }
            try start(index, state: FrameEncoderBlock(kind: .text, coveredChars: content.text.utf16.count))
            return .textStart(contentIndex: index, content: content)
        case .thinkingStart(let index, let partial):
            guard case .thinking(let content) = try eventBlock(index, partial, .thinking) else { return nil }
            try start(index, state: FrameEncoderBlock(kind: .thinking, coveredChars: content.thinking.utf16.count))
            return .thinkingStart(contentIndex: index, content: content)
        case .textDelta(let index, let delta, _): return try textDelta(index, delta, .text)
        case .thinkingDelta(let index, let delta, _): return try textDelta(index, delta, .thinking)
        case .textEnd(let index, let value, let partial):
            guard case .text(let content) = try eventBlock(index, partial, .text) else { return nil }
            try end(index, .text)
            return .textEnd(contentIndex: index, content: value, textSignature: content.textSignature)
        case .thinkingEnd(let index, let value, let partial):
            guard case .thinking(let content) = try eventBlock(index, partial, .thinking) else { return nil }
            try end(index, .thinking)
            return .thinkingEnd(contentIndex: index, content: value, thinkingSignature: content.thinkingSignature, redacted: content.redacted)
        case .toolCallStart(let index, let partial):
            guard case .toolCall(let tool) = try eventBlock(index, partial, .toolCall) else { return nil }
            _ = try JSONEncoder().encode(tool.arguments)
            try start(index, state: FrameEncoderBlock(kind: .toolCall, caughtUp: tool.arguments.isEmpty, snapshotArguments: tool.arguments))
            return .toolCallStart(contentIndex: index, toolCall: tool)
        case .toolCallDelta(let index, let delta, _):
            var state = try block(index, .toolCall)
            if state.caughtUp { return delta.isEmpty ? nil : .toolCallDelta(contentIndex: index, delta: delta) }
            state.catchupJSON += delta
            let arguments = parseFrameToolJSON(state.catchupJSON)
            guard arguments == state.snapshotArguments || frameJSONPrefix(AnyCodable(state.snapshotArguments.mapValues(\.value)), AnyCodable(arguments.mapValues(\.value))) else {
                blocks[index] = state
                return nil
            }
            let json = state.catchupJSON
            state.caughtUp = true
            state.snapshotArguments = [:]
            state.catchupJSON = ""
            blocks[index] = state
            return json.isEmpty ? nil : .toolCallCheckpoint(contentIndex: index, json: json)
        case .toolCallEnd(let index, let tool, let partial):
            _ = try eventBlock(index, partial, .toolCall)
            try end(index, .toolCall)
            return .toolCallEnd(contentIndex: index, toolCall: tool)
        case .start, .done, .error: return nil
        }
    }

    private func eventBlock(_ index: Int, _ partial: AssistantMessage, _ kind: FrameBlockKind) throws -> ContentBlock {
        try checkFrameIndex(index)
        guard partial.content.indices.contains(index) else { throw AssistantMessageFrameError.invalidFrame("Event has no content block at index \(index)") }
        let value = partial.content[index]
        guard frameBlockKind(value) == kind else { throw AssistantMessageFrameError.invalidFrame("Event points to the wrong block kind at index \(index)") }
        return value
    }
    private mutating func start(_ index: Int, state: FrameEncoderBlock) throws {
        try checkFrameIndex(index)
        guard blocks[index] == nil else { throw AssistantMessageFrameError.invalidFrame("Assistant message block \(index) starts more than once") }
        blocks[index] = state
    }
    private func block(_ index: Int, _ kind: FrameBlockKind) throws -> FrameEncoderBlock {
        try checkFrameIndex(index)
        guard let state = blocks[index] else { throw AssistantMessageFrameError.invalidFrame("Assistant message \(kind.rawValue) block \(index) has not started") }
        guard state.kind == kind else { throw AssistantMessageFrameError.invalidFrame("Assistant message block \(index) has the wrong kind") }
        return state
    }
    private mutating func end(_ index: Int, _ kind: FrameBlockKind) throws {
        _ = try block(index, kind)
        blocks.removeValue(forKey: index)
    }
    private mutating func textDelta(_ index: Int, _ delta: String, _ kind: FrameBlockKind) throws -> AssistantMessageFrame? {
        var state = try block(index, kind)
        let start = state.deltaChars
        state.deltaChars += delta.utf16.count
        blocks[index] = state
        let covered = max(0, state.coveredChars - start)
        guard covered < delta.utf16.count else { return nil }
        let uncovered = String(decoding: Array(delta.utf16.dropFirst(covered)), as: UTF16.self)
        return kind == .text ? .textDelta(contentIndex: index, delta: uncovered) : .thinkingDelta(contentIndex: index, delta: uncovered)
    }
}

private struct FrameReducerBlock {
    var kind: FrameBlockKind
    var ended = false
    var json = ""
}

/// Rebuild progress without changing the input frames. No start frame produces nil.
public func reduceAssistantMessageFrames<S: Sequence>(_ frames: S) throws -> AssistantMessage? where S.Element == AssistantMessageFrame {
    var message: AssistantMessage?
    var beforeStart: String?
    var states: [Int: FrameReducerBlock] = [:]
    for frame in frames {
        if case .start(let partial) = frame {
            guard message == nil else { throw AssistantMessageFrameError.invalidFrame("Assistant message frame sequence contains more than one start frame") }
            guard beforeStart == nil else { throw AssistantMessageFrameError.invalidFrame("\(beforeStart!) frame appears before the start frame") }
            message = partial
            continue
        }
        guard var current = message else { beforeStart = beforeStart ?? frame.type; continue }
        guard let index = frame.index else { continue }
        try checkFrameIndex(index)
        let newBlock: ContentBlock?
        switch frame {
        case .textStart(_, let content): newBlock = .text(content)
        case .thinkingStart(_, let content): newBlock = .thinking(content)
        case .toolCallStart(_, let tool): newBlock = .toolCall(tool)
        default: newBlock = nil
        }
        if let newBlock {
            guard index == current.content.count else {
                throw AssistantMessageFrameError.invalidFrame("Cannot start assistant message block at index \(index): \(index < current.content.count ? "already exists" : "would leave a gap")")
            }
            current.content.append(newBlock)
            states[index] = FrameReducerBlock(kind: frameBlockKind(newBlock)!)
            message = current
            continue
        }
        let kind: FrameBlockKind
        switch frame {
        case .textDelta, .textEnd: kind = .text
        case .thinkingDelta, .thinkingEnd: kind = .thinking
        default: kind = .toolCall
        }
        guard var state = states[index], current.content.indices.contains(index) else {
            throw AssistantMessageFrameError.invalidFrame("\(frame.type) frame has no started block at index \(index)")
        }
        guard state.kind == kind, frameBlockKind(current.content[index]) == kind else {
            throw AssistantMessageFrameError.invalidFrame("\(frame.type) frame expected \(kind.rawValue) block at index \(index)")
        }
        guard !state.ended else { throw AssistantMessageFrameError.invalidFrame("\(frame.type) frame follows the end of block at index \(index)") }
        switch frame {
        case .textDelta(_, let delta):
            if case .text(var text) = current.content[index] { text.text += delta; current.content[index] = .text(text) }
        case .textEnd(_, let content, let signature):
            current.content[index] = .text(TextContent(text: content, textSignature: signature)); state.ended = true
        case .thinkingDelta(_, let delta):
            if case .thinking(var thinking) = current.content[index] { thinking.thinking += delta; current.content[index] = .thinking(thinking) }
        case .thinkingEnd(_, let content, let signature, let redacted):
            current.content[index] = .thinking(ThinkingContent(thinking: content, thinkingSignature: signature, redacted: redacted)); state.ended = true
        case .toolCallCheckpoint(_, let json):
            state.json = json
            if case .toolCall(var tool) = current.content[index] { tool.arguments = parseFrameToolJSON(json); current.content[index] = .toolCall(tool) }
        case .toolCallDelta(_, let delta): state.json += delta
        case .toolCallEnd(_, let tool): current.content[index] = .toolCall(tool); state.ended = true
        default: break
        }
        states[index] = state
        message = current
    }
    guard var result = message else { return nil }
    for (index, state) in states where state.kind == .toolCall && !state.ended && !state.json.isEmpty {
        if case .toolCall(var tool) = result.content[index] { tool.arguments = parseFrameToolJSON(state.json); result.content[index] = .toolCall(tool) }
    }
    return result
}

extension AssistantMessageFrame: Codable {
    public func encode(to encoder: any Encoder) throws {
        var object: [String: Any] = ["type": type]
        if let index { object["contentIndex"] = index }
        switch self {
        case .start(let partial): object["partial"] = assistantMessageToJSONObject(partial)
        case .textStart(_, let content): object["content"] = contentBlockToJSONObject(.text(content))
        case .thinkingStart(_, let content): object["content"] = contentBlockToJSONObject(.thinking(content))
        case .toolCallStart(_, let tool): object["toolCall"] = contentBlockToJSONObject(.toolCall(tool))
        case .textDelta(_, let delta), .thinkingDelta(_, let delta), .toolCallDelta(_, let delta): object["delta"] = delta
        case .textEnd(_, let content, let signature):
            object["content"] = content
            if let signature { object["textSignature"] = signature }
        case .thinkingEnd(_, let content, let signature, let redacted):
            object["content"] = content
            if let signature { object["thinkingSignature"] = signature }
            if let redacted { object["redacted"] = redacted }
        case .toolCallCheckpoint(_, let json): object["json"] = json
        case .toolCallEnd(_, let tool):
            for (key, value) in contentBlockToJSONObject(.toolCall(tool)) where key != "type" { object[key] = value }
        }
        try AnyCodable(object).encode(to: encoder)
    }

    public init(from decoder: any Decoder) throws {
        guard let object = try AnyCodable(from: decoder).value as? [String: Any], let type = object["type"] as? String else {
            throw AssistantMessageFrameError.invalidFrame("Invalid assistant message frame")
        }
        if type == "start", let partial = object["partial"] as? [String: Any] {
            self = .start(partial: assistantMessageFromJSONObject(partial)); return
        }
        guard let index = object["contentIndex"] as? Int else { throw AssistantMessageFrameError.invalidFrame("Invalid assistant message frame contentIndex") }
        try checkFrameIndex(index)
        func text(_ key: String) throws -> String {
            guard let value = object[key] as? String else { throw AssistantMessageFrameError.invalidFrame("Missing frame \(key)") }
            return value
        }
        switch type {
        case "text_start":
            guard let value = object["content"] as? [String: Any], case .text(let content) = contentBlockFromJSONObject(value) else { throw AssistantMessageFrameError.invalidFrame("text_start frame requires text content") }
            self = .textStart(contentIndex: index, content: content)
        case "thinking_start":
            guard let value = object["content"] as? [String: Any], case .thinking(let content) = contentBlockFromJSONObject(value) else { throw AssistantMessageFrameError.invalidFrame("thinking_start frame requires thinking content") }
            self = .thinkingStart(contentIndex: index, content: content)
        case "toolcall_start", "toolcall_end":
            var value = type == "toolcall_start" ? object["toolCall"] as? [String: Any] ?? [:] : object
            if type == "toolcall_end" { value["type"] = "toolCall" }
            guard case .toolCall(let tool) = contentBlockFromJSONObject(value) else { throw AssistantMessageFrameError.invalidFrame("\(type) frame requires tool call content") }
            self = type == "toolcall_start" ? .toolCallStart(contentIndex: index, toolCall: tool) : .toolCallEnd(contentIndex: index, toolCall: tool)
        case "text_delta": self = .textDelta(contentIndex: index, delta: try text("delta"))
        case "thinking_delta": self = .thinkingDelta(contentIndex: index, delta: try text("delta"))
        case "toolcall_delta": self = .toolCallDelta(contentIndex: index, delta: try text("delta"))
        case "toolcall_checkpoint": self = .toolCallCheckpoint(contentIndex: index, json: try text("json"))
        case "text_end": self = .textEnd(contentIndex: index, content: try text("content"), textSignature: object["textSignature"] as? String)
        case "thinking_end": self = .thinkingEnd(contentIndex: index, content: try text("content"), thinkingSignature: object["thinkingSignature"] as? String, redacted: object["redacted"] as? Bool)
        default: throw AssistantMessageFrameError.invalidFrame("Unknown assistant message frame type \(type)")
        }
    }
}

/// Frame checkpoints need the unfinished string/object values retained by upstream
/// partial-json. The older provider JSON helper accepts complete objects only.
private func parseFrameToolJSON(_ json: String) -> [String: AnyCodable] {
    if let data = json.data(using: .utf8),
       let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        return object.mapValues(AnyCodable.init)
    }
    var reader = FramePartialJSONReader(characters: Array(json))
    guard case .object(let values)? = reader.readValue() else { return [:] }
    return values
}

private indirect enum FramePartialJSONValue {
    case object([String: AnyCodable])
    case scalar(AnyCodable)

    var codable: AnyCodable {
        switch self {
        case .object(let values): AnyCodable(values.mapValues(\.value))
        case .scalar(let value): value
        }
    }
}

private struct FramePartialJSONReader {
    let characters: [Character]
    var position = 0

    mutating func skipSpace() {
        while position < characters.count, characters[position].isWhitespace { position += 1 }
    }

    mutating func readValue(depth: Int = 0) -> FramePartialJSONValue? {
        guard depth < 512 else { return nil }
        skipSpace()
        guard position < characters.count else { return nil }
        switch characters[position] {
        case "{":
            position += 1
            var object: [String: AnyCodable] = [:]
            while true {
                skipSpace()
                guard position < characters.count else { return .object(object) }
                if characters[position] == "}" { position += 1; return .object(object) }
                guard characters[position] == "\"", let key = readString() else { return .object(object) }
                skipSpace()
                guard position < characters.count, characters[position] == ":" else { return .object(object) }
                position += 1
                guard let value = readValue(depth: depth + 1) else { return .object(object) }
                object[key] = value.codable
                skipSpace()
                guard position < characters.count, characters[position] == "," else {
                    if position < characters.count, characters[position] == "}" { position += 1 }
                    return .object(object)
                }
                position += 1
            }
        case "[":
            position += 1
            var values: [AnyCodable] = []
            while true {
                skipSpace()
                guard position < characters.count else { break }
                if characters[position] == "]" { position += 1; break }
                guard let value = readValue(depth: depth + 1) else { break }
                values.append(value.codable)
                skipSpace()
                guard position < characters.count, characters[position] == "," else {
                    if position < characters.count, characters[position] == "]" { position += 1 }
                    break
                }
                position += 1
            }
            return .scalar(AnyCodable(values.map(\.value)))
        case "\"": return readString().map { .scalar(AnyCodable($0)) }
        default:
            let start = position
            while position < characters.count,
                  !characters[position].isWhitespace,
                  ![",", "}", "]"].contains(characters[position]) { position += 1 }
            let token = String(characters[start..<position])
            if !token.isEmpty, "true".hasPrefix(token) { return .scalar(AnyCodable(true)) }
            if !token.isEmpty, "false".hasPrefix(token) { return .scalar(AnyCodable(false)) }
            if !token.isEmpty, "null".hasPrefix(token) { return .scalar(AnyCodable(NSNull())) }
            if let value = Int(token) { return .scalar(AnyCodable(value)) }
            if let value = Double(token), value.isFinite { return .scalar(AnyCodable(value)) }
            return nil
        }
    }

    mutating func readString() -> String? {
        guard position < characters.count, characters[position] == "\"" else { return nil }
        position += 1
        var value = ""
        while position < characters.count {
            let character = characters[position]
            position += 1
            if character == "\"" { return value }
            guard character == "\\" else { value.append(character); continue }
            guard position < characters.count else { return value }
            let escaped = characters[position]
            position += 1
            switch escaped {
            case "\"", "\\", "/": value.append(escaped)
            case "b": value.append("\u{8}")
            case "f": value.append("\u{c}")
            case "n": value.append("\n")
            case "r": value.append("\r")
            case "t": value.append("\t")
            case "u":
                guard position + 4 <= characters.count else { return value }
                let hex = String(characters[position..<(position + 4)])
                guard let unit = UInt16(hex, radix: 16) else { return value }
                position += 4
                if (0xd800...0xdbff).contains(unit), position + 6 <= characters.count,
                   characters[position] == "\\", characters[position + 1] == "u",
                   let low = UInt16(String(characters[(position + 2)..<(position + 6)]), radix: 16),
                   (0xdc00...0xdfff).contains(low) {
                    value += String(decoding: [unit, low], as: UTF16.self)
                    position += 6
                } else if !(0xd800...0xdfff).contains(unit) {
                    value += String(decoding: [unit], as: UTF16.self)
                }
            default:
                // Same repair as the upstream helper for an invalid JSON escape.
                value.append("\\")
                value.append(escaped)
            }
        }
        return value
    }
}
