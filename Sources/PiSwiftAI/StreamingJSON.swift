import Foundation
import PiSwiftSchema

/// A change made by one piece of streamed JSON.
public struct JSONChange: Sendable, Equatable {
    public enum Kind: String, Sendable { case set, append }
    public enum PathElement: Sendable, Equatable { case key(String), index(Int) }
    public let kind: Kind
    public let path: [PathElement]
    public let value: OrderedJSON?
    public let text: String?

    public init(kind: Kind, path: [PathElement], value: OrderedJSON? = nil, text: String? = nil) {
        self.kind = kind
        self.path = path
        self.value = value
        self.text = text
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && lhs.path == rhs.path && lhs.text == rhs.text &&
        lhs.value?.serialized() == rhs.value?.serialized()
    }
}

/// Incremental tolerant JSON reader. Its owner must keep it within one stream task.
// streaming-json.ts:109
public final class StreamingJSONParser {
    private enum Slot { case root, member(String), element(Int) }
    private enum Phase { case key, colon, value, comma }
    private struct Frame {
        let isArray: Bool
        let slot: Slot?
        let path: [JSONChange.PathElement]?
        let reportsInside: Bool
        var pairs: [(String, OrderedJSON)] = []
        var positions: [String: Int] = [:]
        var items: [OrderedJSON] = []
        var size = 0
        var key: String?
        var phase: Phase
        var value: OrderedJSON { isArray ? .array(items) : .object(pairs) }
    }
    private struct OpenString {
        let isKey: Bool
        let slot: Slot?
        let path: [JSONChange.PathElement]?
        var text = ""
        var unitCount = 0
        var escape = ""
        var changeIndex: Int?
        var pendingHighSurrogate: UInt16?
    }
    private var root: OrderedJSON?
    private var done = false
    private var stack: [Frame] = []
    private var openString: OpenString?
    private var scalar = ""
    private var scalarSlot: Slot?
    private var pathCost = 0
    private var credit = 0
    private var dirty = false
    private var cachedSnapshot: OrderedJSON?
    private(set) var snapshotRevision = 0
    private var changes: [JSONChange] = []

    public init() {}

    /// Read each UTF-16 code unit of this piece once.
    // streaming-json.ts:127
    @discardableResult public func append(_ text: String) -> [JSONChange] {
        let units = Array(text.utf16)
        credit = min(Int.max / 2, credit + 256 + 8 * units.count)
        changes = []
        if openString != nil { openString?.changeIndex = nil }
        var index = 0
        while index < units.count && !done {
            if openString != nil { index = readString(units, from: index) }
            else if !scalar.isEmpty { index = readScalar(units, from: index) }
            else { structural(units[index]); index += 1 }
        }
        return changes
    }

    /// Return an immutable value; a large open path can leave the previous preview in place.
    // streaming-json.ts:146
    public func snapshot() -> OrderedJSON? {
        guard dirty else { return cachedSnapshot }
        let pending = pendingScalar()
        // An open string has no container members to copy. Keep its preview current.
        let cost = pathCost + (pending == nil ? 0 : 1)
        guard cost <= credit else { return cachedSnapshot }
        credit -= cost
        dirty = false
        cachedSnapshot = copyOpenPath(pending)
        snapshotRevision += 1
        return cachedSnapshot
    }

    // streaming-json.ts:158
    private func readString(_ units: [UInt16], from start: Int) -> Int {
        var runStart = start
        var index = start
        while index < units.count {
            let unit = units[index]
            if openString?.escape.isEmpty == false {
                if continueEscape(unit) {
                    runStart = index + 1
                    index += 1
                    continue
                }
                runStart = index
            }
            if unit == 34 {
                if index > runStart { appendString(String(decoding: units[runStart..<index], as: UTF16.self)) }
                endString()
                return index + 1
            }
            if unit == 92 {
                if index > runStart { appendString(String(decoding: units[runStart..<index], as: UTF16.self)) }
                openString?.escape = "\\"
                runStart = index + 1
            }
            index += 1
        }
        if units.count > runStart { appendString(String(decoding: units[runStart..<units.count], as: UTF16.self)) }
        return units.count
    }

    // streaming-json.ts:186
    private func readScalar(_ units: [UInt16], from start: Int) -> Int {
        var end = start
        while end < units.count && !Self.isDelimiter(units[end]) { end += 1 }
        if end > start {
            scalar += String(decoding: units[start..<end], as: UTF16.self)
            if scalarSlot != nil { dirty = true }
        }
        if end < units.count { endScalar() }
        return end
    }

    // streaming-json.ts:198
    private func structural(_ unit: UInt16) {
        switch unit {
        case 32, 9, 10, 13: return
        case 34: startString()
        case 123: openContainer(isArray: false)
        case 91: openContainer(isArray: true)
        case 125, 93: closeContainer()
        case 58:
            if !stack.isEmpty && !stack[stack.count - 1].isArray && stack[stack.count - 1].phase == .colon {
                stack[stack.count - 1].phase = .value
            }
        case 44:
            if !stack.isEmpty { stack[stack.count - 1].phase = stack[stack.count - 1].isArray ? .value : .key }
        default:
            scalar = String(decoding: [unit], as: UTF16.self)
            scalarSlot = valueSlot()
            if scalarSlot != nil { dirty = true }
        }
    }

    // streaming-json.ts:235
    private func valueSlot() -> Slot? {
        guard let frame = stack.last else { return root == nil ? .root : nil }
        if frame.isArray { return .element(frame.items.count) }
        if (frame.phase == .value || frame.phase == .colon), let key = frame.key { return .member(key) }
        return nil
    }

    // streaming-json.ts:246
    private func startString() {
        if let frame = stack.last, !frame.isArray, frame.phase == .key || frame.phase == .comma {
            openString = OpenString(isKey: true, slot: nil, path: nil)
            return
        }
        let slot = valueSlot()
        let path = reportedPath(slot)
        openString = OpenString(isKey: false, slot: slot, path: path)
        place(slot, .string(""))
        if let path {
            changes.append(JSONChange(kind: .set, path: path, value: .string("")))
            openString?.changeIndex = changes.count - 1
        }
    }

    // streaming-json.ts:265
    private func reportedPath(_ slot: Slot?) -> [JSONChange.PathElement]? {
        guard let slot else { return nil }
        switch slot {
        case .root: return []
        case .member(let key):
            guard let frame = stack.last, frame.reportsInside, let path = frame.path else { return nil }
            return path + [.key(key)]
        case .element(let index):
            guard let frame = stack.last, frame.reportsInside, let path = frame.path else { return nil }
            return path + [.index(index)]
        }
    }

    // streaming-json.ts:279
    private func continueEscape(_ unit: UInt16) -> Bool {
        guard let escape = openString?.escape else { return false }
        if escape == "\\" {
            let simple: [UInt16: String] = [34: "\"", 92: "\\", 47: "/", 98: "\u{8}", 102: "\u{c}", 110: "\n", 114: "\r", 116: "\t"]
            if let decoded = simple[unit] { openString?.escape = ""; appendString(decoded); return true }
            if unit == 117 { openString?.escape = "\\u"; return true }
            openString?.escape = ""
            appendString("\\")
            return false
        }
        if Self.isHex(unit) {
            openString?.escape += String(decoding: [unit], as: UTF16.self)
            if openString?.escape.utf16.count ?? 0 < 6 { return true }
            let hex = String((openString?.escape ?? "").dropFirst(2))
            openString?.escape = ""
            if let code = UInt16(hex, radix: 16) { appendEscapedCodeUnit(code) }
            return true
        }
        openString?.escape = ""
        appendString(escape)
        return false
    }

    private func appendEscapedCodeUnit(_ code: UInt16) {
        if let high = openString?.pendingHighSurrogate, (0xDC00...0xDFFF).contains(code) {
            openString?.pendingHighSurrogate = nil
            let scalar = 0x10000 + (UInt32(high - 0xD800) << 10) + UInt32(code - 0xDC00)
            if let unicode = Unicode.Scalar(scalar) { appendString(String(unicode), replacingLastChangeCharacter: true) }
            return
        }
        if (0xD800...0xDBFF).contains(code) { openString?.pendingHighSurrogate = code }
        else { openString?.pendingHighSurrogate = nil }
        appendString(String(decoding: [code], as: UTF16.self), preservePendingSurrogate: true)
    }

    // streaming-json.ts:311
    private func appendString(_ text: String, replacingLastChangeCharacter: Bool = false,
                              preservePendingSurrogate: Bool = false) {
        guard openString != nil else { return }
        if !preservePendingSurrogate { openString?.pendingHighSurrogate = nil }
        if replacingLastChangeCharacter, openString?.text.isEmpty == false {
            openString?.text.removeLast()
            openString?.unitCount -= 1
        }
        openString?.text += text
        openString?.unitCount += text.utf16.count
        guard let open = openString else { return }
        if open.isKey { return }
        dirty = true
        guard let path = open.path else { return }
        if let index = open.changeIndex, index == changes.count - 1 {
            let previous = changes[index]
            if previous.kind == .set {
                var old = previous.value?.stringValue ?? ""
                if replacingLastChangeCharacter && !old.isEmpty { old.removeLast() }
                changes[index] = JSONChange(kind: .set, path: path, value: .string(old + text))
            } else {
                var old = previous.text ?? ""
                if replacingLastChangeCharacter && !old.isEmpty { old.removeLast() }
                changes[index] = JSONChange(kind: .append, path: path, text: old + text)
            }
        } else {
            changes.append(JSONChange(kind: .append, path: path, text: text))
            openString?.changeIndex = changes.count - 1
        }
    }

    // streaming-json.ts:326
    private func endString() {
        guard let open = openString else { return }
        openString = nil
        if open.isKey {
            if !stack.isEmpty { stack[stack.count - 1].key = open.text; stack[stack.count - 1].phase = .colon }
        } else { place(open.slot, .string(open.text)); valueEnded() }
    }

    // streaming-json.ts:338
    private func endScalar() {
        let token = scalar
        let slot = scalarSlot
        scalar = ""
        scalarSlot = nil
        if let value = Self.scalarValue(token) {
            place(slot, value)
            if let path = reportedPath(slot) { changes.append(JSONChange(kind: .set, path: path, value: value)) }
        }
        valueEnded()
    }

    // streaming-json.ts:353
    private func pendingScalar() -> (Slot, OrderedJSON)? {
        guard let slot = scalarSlot, !scalar.isEmpty, scalar.utf16.count <= 64,
              let value = Self.pendingScalarValue(scalar) else { return nil }
        return (slot, value)
    }

    // streaming-json.ts:361
    private func openContainer(isArray: Bool) {
        let slot = valueSlot()
        let path = reportedPath(slot)
        place(slot, isArray ? .array([]) : .object([]))
        stack.append(Frame(isArray: isArray, slot: slot, path: path,
                           reportsInside: path != nil && (path?.count ?? 0) < 32,
                           phase: isArray ? .value : .key))
        pathCost += 1
        dirty = true
        if let path { changes.append(JSONChange(kind: .set, path: path, value: isArray ? .array([]) : .object([]))) }
        if stack.count > toolArgumentsMaximumDepth { done = true }
    }

    // streaming-json.ts:380
    private func closeContainer() {
        guard let frame = stack.popLast() else { return }
        pathCost -= frame.size + 1
        dirty = true
        place(frame.slot, frame.value)
        if let path = frame.path, !frame.reportsInside {
            changes.append(JSONChange(kind: .set, path: path, value: frame.value))
        }
        valueEnded()
    }

    // streaming-json.ts:393
    private func valueEnded() {
        if stack.isEmpty { if root != nil { done = true } }
        else { stack[stack.count - 1].phase = .comma }
    }

    // streaming-json.ts:404
    private func place(_ slot: Slot?, _ value: OrderedJSON) {
        guard let slot else { return }
        dirty = true
        switch slot {
        case .root: root = value
        case .element(let index):
            guard !stack.isEmpty else { return }
            let last = stack.count - 1
            if index == stack[last].items.count {
                stack[last].items.append(value)
                stack[last].size += 1
                pathCost += 1
            } else if stack[last].items.indices.contains(index) { stack[last].items[index] = value }
        case .member(let key):
            guard !stack.isEmpty else { return }
            let last = stack.count - 1
            if let index = stack[last].positions[key] { stack[last].pairs[index].1 = value }
            else {
                stack[last].positions[key] = stack[last].pairs.count
                stack[last].pairs.append((key, value))
                stack[last].size += 1
                pathCost += 1
            }
        }
    }

    // streaming-json.ts:430
    private func copyOpenPath(_ pending: (Slot, OrderedJSON)?) -> OrderedJSON? {
        let pending = openString.flatMap { open in
            open.isKey ? nil : open.slot.map { ($0, OrderedJSON.string(open.text)) }
        } ?? pending
        if stack.isEmpty { return pending.map { if case .root = $0.0 { return $0.1 }; return root ?? .null } ?? root }
        var child: OrderedJSON?
        var childSlot: Slot?
        for frame in stack.reversed() {
            var value = frame.value
            if child == nil, let pending { Self.setSlot(&value, pending.0, pending.1) }
            if let child, let childSlot { Self.setSlot(&value, childSlot, child) }
            child = value
            childSlot = frame.slot
        }
        if case .root? = childSlot { return child }
        return root
    }

    private static func setSlot(_ container: inout OrderedJSON, _ slot: Slot, _ value: OrderedJSON) {
        switch (container, slot) {
        case (.array(var items), .element(let index)):
            if index == items.count { items.append(value) }
            else if items.indices.contains(index) { items[index] = value }
            container = .array(items)
        case (.object(var pairs), .member(let key)):
            if let index = pairs.firstIndex(where: { $0.0 == key }) { pairs[index].1 = value }
            else { pairs.append((key, value)) }
            container = .object(pairs)
        default: break
        }
    }

    private static func isDelimiter(_ c: UInt16) -> Bool { [32, 9, 10, 13, 44, 58, 123, 125, 91, 93, 34].contains(c) }
    private static func isHex(_ c: UInt16) -> Bool { (48...57).contains(c) || (65...70).contains(c) || (97...102).contains(c) }
    private static func scalarValue(_ token: String) -> OrderedJSON? {
        switch token { case "true": return .bool(true); case "false": return .bool(false); case "null": return .null; default: break }
        return isNumber(token) ? .number(Self.jsNumber(token)) : nil
    }
    private static func pendingScalarValue(_ token: String) -> OrderedJSON? {
        for (word, value): (String, OrderedJSON) in [("true", .bool(true)), ("false", .bool(false)), ("null", .null)] where word.hasPrefix(token) { return value }
        if isNumber(token) { return .number(jsNumber(token)) }
        if let marker = token.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            let suffix = token[token.index(after: marker)...]
            if suffix.isEmpty || suffix == "+" || suffix == "-" {
                let mantissa = String(token[..<marker])
                if isNumber(mantissa) { return .number(jsNumber(mantissa)) }
            }
        }
        return nil
    }
    private static func isNumber(_ token: String) -> Bool {
        token.range(of: #"^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil
    }
    private static func jsNumber(_ token: String) -> String {
        let number = javaScriptNumber(from: token)
        guard !number.isNaN else { return token }
        if number.isInfinite { return number < 0 ? "-Infinity" : "Infinity" }
        return javaScriptNumberText(number)
    }
}

/// Private raw argument text and parser state for one streamed tool call.
// streaming-json.ts:452
public final class ToolCallArgumentsStream {
    public private(set) var text = ""
    private var parser = StreamingJSONParser()
    private var lastRevision = -1
    private var lastArguments: [String: AnyCodable] = [:]
    public init() {}

    // streaming-json.ts:465
    @discardableResult public func append(_ delta: String) -> [String: AnyCodable] {
        text += delta
        parser.append(delta)
        return partial()
    }

    // streaming-json.ts:474
    public func replace(_ fullText: String) -> (delta: String?, arguments: [String: AnyCodable]) {
        if fullText.hasPrefix(text) {
            let delta = String(fullText.dropFirst(text.count))
            return (delta, delta.isEmpty ? partial() : append(delta))
        }
        text = ""
        parser = StreamingJSONParser()
        lastRevision = -1
        lastArguments = [:]
        return (nil, append(fullText))
    }

    // streaming-json.ts:485
    public func finish() -> (arguments: [String: AnyCodable], argumentsError: String?) {
        parseToolCallArguments(text)
    }

    // streaming-json.ts:489
    private func partial() -> [String: AnyCodable] {
        let snapshot = parser.snapshot()
        guard parser.snapshotRevision != lastRevision else { return lastArguments }
        lastRevision = parser.snapshotRevision
        if case .object = snapshot { lastArguments = snapshot.map { partialJSONValue($0) as? [String: Any] ?? [:] }?.mapValues(AnyCodable.init) ?? [:] }
        else { lastArguments = [:] }
        return lastArguments
    }
}
