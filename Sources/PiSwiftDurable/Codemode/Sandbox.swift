import PiSwiftChord

/// A host-controlled script engine. A start name must stay the same during replay.
/// The fingerprint must identify the engine and deterministic scheduler version.
/// A different engine or scheduler must use a different fingerprint. QuickJS and
/// JavaScriptCore do not have compatible fingerprints.
public protocol CodemodeSandbox: Sendable {
    func start(source: String, name: String, options: CodemodeRunOptions) async throws -> any CodemodeRun
}

/// A run whose host call results can be replayed in a fixed order.
public protocol CodemodeRun: Sendable {
    /// The terminal result. This does not require that the engine has stopped.
    var result: CodemodeResult { get async }
    /// True as soon as the terminal result is selected.
    var finished: Bool { get async }
    /// Buffers results until all earlier sequence numbers arrive. Earlier times cannot move the clock back.
    /// Invalid input must leave the call waiting. Delivery after completion has no effect.
    func deliver(seq: Int, now: Double, id: Int, outcome: CodemodeOutcome) async throws
    /// Ends the run with an aborted error. The first terminal result wins.
    func abort(message: String) async
}

public struct CodemodeDeclaredTool: Sendable, Equatable, Codable {
    public var name: String
    public var jsName: String?
    public var description: String?
    public init(name: String, jsName: String? = nil, description: String? = nil) {
        self.name = name; self.jsName = jsName; self.description = description
    }
    public var scriptName: String { jsName ?? codemodeIdentifier(name) }
}

public struct CodemodeDeclaredGlobal: Sendable, Equatable, Codable {
    public var name: String
    public var spread: Bool
    public init(name: String, spread: Bool = false) { self.name = name; self.spread = spread }
}

public struct CodemodeRunOptions: Sendable {
    public var startedAt: Double
    public var seed: UInt32
    public var tools: [CodemodeDeclaredTool]
    public var globals: [CodemodeDeclaredGlobal]
    public var store: JSONObject
    public var timeoutMs: Double?
    /// Engines must await this callback before they issue calls. The handle permits delivery during start.
    /// Include the engine identity and deterministic scheduler version in the fingerprint.
    public var onStarted: @Sendable (String, any CodemodeRun) async -> Void
    public var onCall: @Sendable (CodemodeHostCall, any CodemodeRun) async -> Void
    /// No idle event is sent for a drain that ends the script.
    public var onIdle: @Sendable (Int, Int, any CodemodeRun) async -> Void
    public init(startedAt: Double, seed: UInt32, tools: [CodemodeDeclaredTool] = [],
                globals: [CodemodeDeclaredGlobal] = [], store: JSONObject = [:], timeoutMs: Double? = nil,
                onStarted: @escaping @Sendable (String, any CodemodeRun) async -> Void = { _, _ in },
                onCall: @escaping @Sendable (CodemodeHostCall, any CodemodeRun) async -> Void = { _, _ in },
                onIdle: @escaping @Sendable (Int, Int, any CodemodeRun) async -> Void = { _, _, _ in }) {
        self.startedAt = startedAt; self.seed = seed; self.tools = tools; self.globals = globals
        self.store = store; self.timeoutMs = timeoutMs
        self.onStarted = onStarted; self.onCall = onCall; self.onIdle = onIdle
    }
    /// Checks values at the JSON and declaration boundaries before an engine starts.
    public func validate() throws {
        guard startedAt.isFinite, startedAt >= 0 else { throw CodemodeProtocolError.invalidClock }
        guard store.values.allSatisfy(\.isStrictJSON) else { throw CodemodeProtocolError.invalidJSON }
        var toolNames: Set<[UInt16]> = []
        var scriptNames: Set<[UInt16]> = []
        for tool in tools {
            guard toolNames.insert(Array(tool.name.utf16)).inserted, scriptNames.insert(Array(tool.scriptName.utf16)).inserted else { throw CodemodeProtocolError.invalidToolName(tool.name) }
        }
        var names: Set<[UInt16]> = []
        var namespaces: Set<[UInt16]> = []
        let reserved = Set(["tools", "ALL_TOOLS", "console", "text", "image", "exit", "globalThis", "store", "load"].map { Array($0.utf16) })
        for global in globals {
            let parts = global.name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard (1...2).contains(parts.count), parts.allSatisfy(isCodemodeIdentifier),
                  !reserved.contains(Array(parts[0].utf16)), names.insert(Array(global.name.utf16)).inserted else {
                throw CodemodeProtocolError.invalidGlobalName(global.name)
            }
            if parts.count == 2 { namespaces.insert(Array(parts[0].utf16)) }
        }
        if let conflict = namespaces.first(where: { names.contains($0) }) {
            throw CodemodeProtocolError.invalidGlobalName(String(decoding: conflict, as: UTF16.self))
        }
    }
}

public enum CodemodeCallTarget: String, Sendable, Equatable, Codable { case tool, global }
public struct CodemodeHostCall: Sendable, Equatable {
    public var id: Int
    public var target: CodemodeCallTarget
    public var name: String
    /// Nil represents JavaScript undefined. Null is `.null`.
    public var args: JSONValue?
    public init(id: Int, target: CodemodeCallTarget, name: String, args: JSONValue? = nil) {
        self.id = id; self.target = target; self.name = name; self.args = args
    }
}

public enum CodemodeOutcome: Sendable, Equatable {
    case success(JSONValue?)
    /// Properties must be own JSON properties. Engines ignore name, message, and stack.
    case failure(message: String, properties: JSONObject = [:])
    public var isStrictJSON: Bool {
        switch self {
        case .success(let value): value?.isStrictJSON ?? true
        case .failure(_, let properties): properties.values.allSatisfy(\.isStrictJSON)
        }
    }
    public var errorProperties: JSONObject {
        guard case .failure(_, var properties) = self else { return [:] }
        for key in ["name", "message", "stack"] { properties.removeValue(forKey: key) }
        return properties
    }
}

public struct CodemodeDuring: Sendable, Equatable, Codable {
    public var seq: Int
    public var issued: Int
    public init(seq: Int, issued: Int) { self.seq = seq; self.issued = issued }
}
public enum CodemodeOutputItem: Sendable, Equatable {
    case text(String, console: Bool = false)
    case image(data: String, mimeType: String)
}
public enum CodemodeCallStatus: String, Sendable, Equatable, Codable { case ok, error, cancelled }
public struct CodemodeCall: Sendable, Equatable, Codable {
    public var name: String
    public var status: CodemodeCallStatus
    public var durationMs: Double
    public init(name: String, status: CodemodeCallStatus, durationMs: Double = 0) {
        self.name = name; self.status = status; self.durationMs = durationMs
    }
}
public struct CodemodeStoreWrites: Sendable, Equatable, Codable {
    public var set: JSONObject
    public var delete: [String]
    public init(set: JSONObject = [:], delete: [String] = []) { self.set = set; self.delete = delete }
}
public enum CodemodeErrorKind: String, Sendable, Equatable, Codable { case script, timeout, aborted, sandbox }
public struct CodemodeError: Error, Sendable, Equatable, Codable {
    public var kind: CodemodeErrorKind
    public var name: String?
    public var message: String
    public var stack: String?
    public init(kind: CodemodeErrorKind, name: String? = nil, message: String, stack: String? = nil) {
        self.kind = kind; self.name = name; self.message = message; self.stack = stack
    }
}
public struct CodemodeResult: Sendable, Equatable {
    public var value: JSONValue?
    public var error: CodemodeError?
    public var output: [CodemodeOutputItem]
    public var calls: [CodemodeCall]
    public var storeWrites: CodemodeStoreWrites?
    public var during: CodemodeDuring?
    public var ok: Bool { error == nil }
    public init(value: JSONValue? = nil, error: CodemodeError? = nil, output: [CodemodeOutputItem] = [],
                calls: [CodemodeCall] = [], storeWrites: CodemodeStoreWrites? = .init(), during: CodemodeDuring? = nil) {
        self.value = value; self.error = error; self.output = output; self.calls = calls
        self.storeWrites = error == nil ? storeWrites : nil; self.during = during
    }
}

public enum CodemodeProtocolError: Error, Sendable, Equatable {
    case invalidClock, invalidJSON, invalidSequence(Int), callNotWaiting(Int)
    case invalidToolName(String), invalidGlobalName(String), invalidSourceName, undeclaredCall(String)
}

/// Uses the identifier mapping pinned by the TypeScript host.
public func codemodeIdentifier(_ name: String) -> String {
    var result = ""
    for scalar in name.unicodeScalars {
        let letter = (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
        let digit = (48...57).contains(scalar.value)
        result.unicodeScalars.append(letter || scalar == "_" || scalar == "$" || (!result.isEmpty && digit) ? scalar : "_")
    }
    return result.isEmpty ? "_" : result
}
private func isCodemodeIdentifier(_ name: String) -> Bool { !name.isEmpty && codemodeIdentifier(name) == name }


extension CodemodeOutcome: Codable {
    private enum CodingKeys: String, CodingKey { case ok, value, message, properties }
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        if try fields.decode(Bool.self, forKey: .ok) {
            self = .success(fields.contains(.value) ? Optional.some(try fields.decode(JSONValue.self, forKey: .value)) : Optional<JSONValue>.none)
        } else {
            self = .failure(message: try fields.decode(String.self, forKey: .message),
                            properties: fields.contains(.properties) ? try fields.decode(JSONObject.self, forKey: .properties) : [:])
        }
        guard isStrictJSON else { throw CodemodeProtocolError.invalidJSON }
    }
    public func encode(to encoder: any Encoder) throws {
        guard isStrictJSON else { throw CodemodeProtocolError.invalidJSON }
        var fields = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .success(let value):
            try fields.encode(true, forKey: .ok)
            if let value { try fields.encode(value, forKey: .value) }
        case .failure(let message, let properties):
            try fields.encode(false, forKey: .ok)
            try fields.encode(message, forKey: .message)
            if !properties.isEmpty { try fields.encode(properties, forKey: .properties) }
        }
    }
}

extension CodemodeHostCall: Codable {
    private enum CodingKeys: String, CodingKey { case id, target, name, args }
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = try fields.decode(Int.self, forKey: .id)
        target = try fields.decode(CodemodeCallTarget.self, forKey: .target)
        name = try fields.decode(String.self, forKey: .name)
        args = fields.contains(.args) ? Optional.some(try fields.decode(JSONValue.self, forKey: .args)) : Optional<JSONValue>.none
    }
    public func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(id, forKey: .id); try fields.encode(target, forKey: .target); try fields.encode(name, forKey: .name)
        if let args { try fields.encode(args, forKey: .args) }
    }
}

extension CodemodeOutputItem: Codable {
    private enum CodingKeys: String, CodingKey { case type, text, console, data, mimeType }
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        switch try fields.decode(String.self, forKey: .type) {
        case "text": self = .text(try fields.decode(String.self, forKey: .text), console: try fields.decodeIfPresent(Bool.self, forKey: .console) ?? false)
        case "image": self = .image(data: try fields.decode(String.self, forKey: .data), mimeType: try fields.decode(String.self, forKey: .mimeType))
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: fields, debugDescription: "Unknown codemode output type")
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text, let console):
            try fields.encode("text", forKey: .type); try fields.encode(text, forKey: .text)
            if console { try fields.encode(true, forKey: .console) }
        case .image(let data, let mimeType):
            try fields.encode("image", forKey: .type); try fields.encode(data, forKey: .data); try fields.encode(mimeType, forKey: .mimeType)
        }
    }
}

extension CodemodeResult: Codable {
    private enum CodingKeys: String, CodingKey { case ok, value, error, output, calls, storeWrites, during }
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        let ok = try fields.decode(Bool.self, forKey: .ok)
        self.init(value: ok && fields.contains(.value) ? Optional.some(try fields.decode(JSONValue.self, forKey: .value)) : Optional<JSONValue>.none,
                  error: ok ? nil : try fields.decode(CodemodeError.self, forKey: .error),
                  output: try fields.decode([CodemodeOutputItem].self, forKey: .output),
                  calls: try fields.decode([CodemodeCall].self, forKey: .calls),
                  storeWrites: ok ? try fields.decode(CodemodeStoreWrites.self, forKey: .storeWrites) : nil,
                  during: try fields.decodeIfPresent(CodemodeDuring.self, forKey: .during))
    }
    public func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(ok, forKey: .ok); try fields.encode(output, forKey: .output); try fields.encode(calls, forKey: .calls)
        try fields.encodeIfPresent(during, forKey: .during)
        if let error { try fields.encode(error, forKey: .error) }
        else {
            if let value { try fields.encode(value, forKey: .value) }
            try fields.encode(storeWrites ?? .init(), forKey: .storeWrites)
        }
    }
}


private func codemodeEqual(_ lhs: String, _ rhs: String) -> Bool { lhs.utf16.elementsEqual(rhs.utf16) }
private func codemodeEqual(_ lhs: String?, _ rhs: String?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil): true
    case (.some(let lhs), .some(let rhs)): codemodeEqual(lhs, rhs)
    default: false
    }
}
private func codemodeEqual(_ lhs: JSONObject, _ rhs: JSONObject) -> Bool { lhs == rhs }

extension CodemodeDeclaredTool {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        codemodeEqual(lhs.name, rhs.name) && codemodeEqual(lhs.jsName, rhs.jsName) && codemodeEqual(lhs.description, rhs.description)
    }
}
extension CodemodeDeclaredGlobal {
    public static func == (lhs: Self, rhs: Self) -> Bool { codemodeEqual(lhs.name, rhs.name) && lhs.spread == rhs.spread }
}
extension CodemodeHostCall {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.target == rhs.target && codemodeEqual(lhs.name, rhs.name) && lhs.args == rhs.args
    }
}
extension CodemodeOutcome {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.success(let lhs), .success(let rhs)): lhs == rhs
        case (.failure(let lhsMessage, let lhsProperties), .failure(let rhsMessage, let rhsProperties)):
            codemodeEqual(lhsMessage, rhsMessage) && codemodeEqual(lhsProperties, rhsProperties)
        default: false
        }
    }
}
extension CodemodeOutputItem {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.text(let lhsText, let lhsConsole), .text(let rhsText, let rhsConsole)):
            codemodeEqual(lhsText, rhsText) && lhsConsole == rhsConsole
        case (.image(let lhsData, let lhsMime), .image(let rhsData, let rhsMime)):
            codemodeEqual(lhsData, rhsData) && codemodeEqual(lhsMime, rhsMime)
        default: false
        }
    }
}
extension CodemodeCall {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        codemodeEqual(lhs.name, rhs.name) && lhs.status == rhs.status && lhs.durationMs == rhs.durationMs
    }
}
extension CodemodeStoreWrites {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        codemodeEqual(lhs.set, rhs.set) && lhs.delete.count == rhs.delete.count && zip(lhs.delete, rhs.delete).allSatisfy { codemodeEqual($0.0, $0.1) }
    }
}
extension CodemodeError {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && codemodeEqual(lhs.name, rhs.name) && codemodeEqual(lhs.message, rhs.message) && codemodeEqual(lhs.stack, rhs.stack)
    }
}
extension CodemodeProtocolError {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.invalidClock, .invalidClock), (.invalidJSON, .invalidJSON), (.invalidSourceName, .invalidSourceName): true
        case (.invalidSequence(let lhs), .invalidSequence(let rhs)), (.callNotWaiting(let lhs), .callNotWaiting(let rhs)): lhs == rhs
        case (.invalidToolName(let lhs), .invalidToolName(let rhs)), (.invalidGlobalName(let lhs), .invalidGlobalName(let rhs)),
             (.undeclaredCall(let lhs), .undeclaredCall(let rhs)): codemodeEqual(lhs, rhs)
        default: false
        }
    }
}
