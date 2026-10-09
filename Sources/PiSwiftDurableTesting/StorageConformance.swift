import PiSwiftChord
import PiSwiftDurable

/// A check that can run with any asynchronous test runner.
public struct StorageConformanceCase: Sendable, CustomStringConvertible {
    /// The name reported for this storage contract check.
    public let name: String
    /// Runs the asynchronous storage contract check.
    public let run: @Sendable () async throws -> Void
    /// Pairs a storage test name with its asynchronous check body.
    public init(name: String, run: @escaping @Sendable () async throws -> Void) {
        self.name = name
        self.run = run
    }
    /// Text that describes this value or error to the caller.
    public var description: String { name }
}

/// A failed storage check, with its source location.
public struct StorageConformanceFailure: Error, Sendable, CustomStringConvertible {
    /// Text that describes the error, diagnostic, or model response.
    public let message: String
    /// The source file in which the check failed.
    public let file: String
    /// The source line at which the check failed.
    public let line: UInt
    /// Stores a failed check message with its source file and line.
    public init(_ message: String, file: String = #filePath, line: UInt = #line) {
        self.message = message
        self.file = file
        self.line = line
    }
    /// Text that describes this value or error to the caller.
    public var description: String { "\(file):\(line): \(message)" }
}

/// Creates the upstream storage checks. The provider must call and await its callback once per case.
public func storageConformanceCases(
    withStorage: @escaping @Sendable (@Sendable (any DurableStorage) async throws -> Void) async throws -> Void
) -> [StorageConformanceCase] {
    let cases: [(String, @Sendable (StorageChecks) async throws -> Void)] = [
        ("reserves ID 1 for the immutable root conversation", StorageChecks.case1),
        ("commits mixed table writes atomically and rolls all of them back on failure", StorageChecks.case2),
        ("detaches retained writes and every returned record", StorageChecks.case3),
        ("detaches prototype-like JSON keys without changing object prototypes", StorageChecks.case4),
        ("indexes entries committed out of ID order", StorageChecks.case5),
        ("continues an entry cursor below its last item after a newer commit", StorageChecks.case6),
        ("paginates conversations by opaque cursor in ascending ID order", StorageChecks.case7),
        ("filters and pages conversations by durable owner edges", StorageChecks.case8),
        ("scans deep fork history newest-first through every ancestor cap", StorageChecks.case9),
        ("scans tables in either ID order and continues a cursor in its order", StorageChecks.case10),
        ("replaces complete task records and pages filtered task scans", StorageChecks.case11),
        ("stores owners and scans waiting and completing tasks by status", StorageChecks.case12),
        ("indexes request IDs per conversation and replaces complete submission records", StorageChecks.case13),
        ("stores passive write submissions without input-only lifecycle states", StorageChecks.case14),
        ("reconstructs rewindable documents and preserves half-open incarnations", StorageChecks.case15),
        ("streams long document tails across root replacement deltas", StorageChecks.case16),
        ("copies stored document bases independently and rejects ambiguous sources", StorageChecks.case17),
        ("uses bases for version transitions and rejects historical reads of current-only documents", StorageChecks.case18),
        ("indexes logical addresses and exact-scope scans independently", StorageChecks.case19),
        ("keeps document lifecycle failures atomic and gives create-plus-retire an empty lifetime", StorageChecks.case20),
        ("rolls back record tables and secondary indexes when a document command fails", StorageChecks.case21),
        ("keeps indexed string identities lossless", StorageChecks.case22),
        ("keeps one global record ID namespace and rejects exhausted ID minting", StorageChecks.case23),
        ("rejects every operation after close", StorageChecks.case24),
    ]
    return cases.map { name, check in
        StorageConformanceCase(name: name) {
            try await withStorage { storage in try await check(StorageChecks(storage: storage)) }
        }
    }
}

internal enum StorageAssertions {
    static func ok(_ value: Bool, _ message: String = "Expected value to be true", file: String = #filePath, line: UInt = #line) throws {
        guard value else { throw StorageConformanceFailure(message, file: file, line: line) }
    }
    static func strictEqual<T: Equatable>(_ actual: T, _ expected: T, file: String = #filePath, line: UInt = #line) throws {
        // JSONValue compares strings by Unicode scalar identity.
        try ok(actual == expected, "Expected \(String(describing: expected)); got \(String(describing: actual))", file: file, line: line)
    }
    static func deepEqual(_ actual: JSONValue?, _ expected: JSONValue?, file: String = #filePath, line: UInt = #line) throws {
        try strictEqual(actual, expected, file: file, line: line)
    }
    static func partialDeepEqual(_ actual: JSONValue?, _ expected: JSONValue, file: String = #filePath, line: UInt = #line) throws {
        func matches(_ actual: JSONValue?, _ expected: JSONValue) -> Bool {
            switch expected {
            case .object(let members):
                guard let object = actual?.objectValue else { return false }
                return members.allSatisfy { matches(object[$0.key], $0.value) }
            case .array(let members):
                guard let array = actual?.arrayValue, array.count == members.count else { return false }
                return zip(array, members).allSatisfy { matches($0.0, $0.1) }
            default: return actual == expected
            }
        }
        try ok(matches(actual, expected), "Expected partial value \(expected); got \(String(describing: actual))", file: file, line: line)
    }
    static func greaterThan<T: Comparable>(_ actual: T, _ expected: T, file: String = #filePath, line: UInt = #line) throws {
        try ok(actual > expected, "Expected \(actual) to be greater than \(expected)", file: file, line: line)
    }
    static func rejects<T: Sendable>(messageIncludes: String, file: String = #filePath, line: UInt = #line,
                                     _ operation: () async throws -> T) async throws {
        do { _ = try await operation() }
        catch {
            try ok(String(describing: error).contains(messageIncludes), "Expected error containing \(messageIncludes); got \(error)", file: file, line: line)
            return
        }
        throw StorageConformanceFailure("Expected rejection containing \(messageIncludes)", file: file, line: line)
    }
}

internal struct StorageChecks: Sendable {
    let storage: any DurableStorage
    static let context = ChordContext.background
    static func number(_ id: Int64) -> JSONValue { .number(Double(id)) }
    func mint() async throws -> Int64 {
        let id: EntryID = try await storage.mintId()
        return id.rawValue
    }
    @discardableResult func commit(_ writes: [JSONValue]) async throws -> Int64 {
        try await storage.commit(writes.map { try $0.decode(StorageWrite.self) }, context: Self.context).rawValue
    }
    @discardableResult func root() async throws -> Int64 { try await commit([Self.write("conversation", ["id": 1])]); return 1 }
    static func write(_ type: String, _ value: JSONValue) -> JSONValue { ["type": .string(type), "value": value] }
    static func entry(_ id: Int64, _ conversation: Int64, _ kind: String = "message", _ extra: JSONObject = [:]) -> JSONValue {
        var value = extra
        value["id"] = number(id); value["conversationId"] = number(conversation); value["kind"] = .string(kind)
        return .object(value)
    }
    static func task(_ id: Int64, _ conversation: Int64, _ extra: JSONObject = [:]) -> JSONValue {
        var value: JSONObject = ["id": number(id), "conversationId": number(conversation), "kind": "test.task", "version": 1,
                                  "input": ["value": number(id)], "state": ["status": "pending", "checkpoint": ["phase": "ready"]],
                                  "background": false, "abortRequested": false]
        for (key, member) in extra { value[key] = member }
        return .object(value)
    }
    static func submission(_ id: Int64, _ conversation: Int64, _ extra: JSONObject = [:]) -> JSONValue {
        var value: JSONObject = ["id": number(id), "conversationId": number(conversation), "type": "input", "status": "queued"]
        for (key, member) in extra { value[key] = member }
        return .object(value)
    }
    static func replacing(_ value: JSONValue, _ members: JSONObject) -> JSONValue {
        var result = value.objectValue!
        for (key, member) in members { result[key] = member }
        return .object(result)
    }
    static func scope(_ conversation: Int64) -> JSONValue { ["kind": "conversation", "conversationId": number(conversation)] }
    static func documentRecord(_ id: Int64, _ kind: String, _ scope: JSONValue, _ extra: JSONObject = [:]) -> JSONValue {
        var record = extra
        record["id"] = number(id); record["kind"] = .string(kind); record["scope"] = scope
        return .object(record)
    }
    static func create(_ record: JSONValue, _ value: JSONValue, version: Int64 = 1) -> JSONValue {
        ["type": "document.create", "record": record, "content": ["kind": "base", "version": number(version), "value": value]]
    }
    static func change(_ id: Int64, _ ops: JSONValue, version: Int64 = 1) -> JSONValue {
        ["type": "document.change", "id": number(id), "content": ["kind": "delta", "version": number(version), "ops": ops]]
    }
    static func base(_ id: Int64, _ value: JSONValue, version: Int64 = 1) -> JSONValue {
        ["type": "document.change", "id": number(id), "content": ["kind": "base", "version": number(version), "value": value]]
    }
    static func retire(_ id: Int64) -> JSONValue { ["type": "document.retire", "id": number(id)] }
    static func copy(_ record: JSONValue, _ id: Int64, _ at: JSONValue = "current") -> JSONValue {
        ["type": "document.copy", "record": record, "source": ["id": number(id), "at": at]]
    }
    func conversation(_ id: Int64) async throws -> JSONValue? { try await storage.conversation(ConversationID(id), context: Self.context).map { try JSONValue(encoding: $0) } }
    func entry(_ id: Int64, in conversation: Int64? = nil) async throws -> JSONValue? {
        let result: EntryLookup?
        if let conversation { result = try await storage.entry(ConversationID(conversation), id: EntryID(id), context: Self.context) }
        else { result = try await storage.entry(EntryID(id), context: Self.context) }
        return try result.map { try JSONValue(encoding: $0) }
    }
    func marker(_ conversation: Int64, _ at: Int64? = nil) async throws -> JSONValue? {
        try await storage.findLatestHeadMarker(ConversationID(conversation), atOrBeforeEntryId: at.map { try EntryID($0) }, context: Self.context).map { try JSONValue(encoding: $0) }
    }
    func task(_ id: Int64) async throws -> JSONValue? { try await storage.task(TaskID(id), context: Self.context).map { try JSONValue(encoding: $0) } }
    func submission(_ id: Int64) async throws -> JSONValue? { try await storage.submission(SubmissionID(id), context: Self.context).map { try JSONValue(encoding: $0) } }
    func request(_ conversation: Int64, _ requestId: String) async throws -> JSONValue? {
        try await storage.submissionByRequest(ConversationID(conversation), requestId: requestId, context: Self.context).map { try JSONValue(encoding: $0) }
    }
    func document(_ id: Int64, _ at: JSONValue = "current") async throws -> JSONValue? {
        try await storage.document(DocumentID(id), at: at.decode(DocumentPoint.self), context: Self.context).map { try JSONValue(encoding: $0) }
    }
    func find(_ address: JSONValue, _ at: JSONValue = "current") async throws -> JSONValue? {
        try await storage.findDocument(address.decode(DocumentAddress.self), at: at.decode(DocumentPoint.self), context: Self.context).map { try JSONValue(encoding: $0) }
    }
    struct ScanPage: Sendable {
        let items: [JSONValue]
        let next: Cursor?
        var ids: [Int64] { items.map { $0["id"]!.int64Value! } }
    }
    func scan(_ table: String, _ query: JSONValue = [:], _ limit: Int = 10, _ cursor: Cursor? = nil) async throws -> ScanPage {
        func page<T>(_ value: Page<T, Cursor>) throws -> ScanPage { try ScanPage(items: value.items.map { try JSONValue(encoding: $0) }, next: value.next) }
        switch table {
        case "conversation": return try page(await storage.scanConversations(query.decode(ConversationQuery.self), limit: limit, cursor: cursor, context: Self.context))
        case "entry": return try page(await storage.scanEntries(query.decode(EntryQuery.self), limit: limit, cursor: cursor, context: Self.context))
        case "task": return try page(await storage.scanTasks(query.decode(TaskQuery.self), limit: limit, cursor: cursor, context: Self.context))
        case "submission": return try page(await storage.scanSubmissions(query.decode(SubmissionQuery.self), limit: limit, cursor: cursor, context: Self.context))
        default: return try page(await storage.scanDocuments(query.decode(DocumentQuery.self), limit: limit, cursor: cursor, context: Self.context))
        }
    }
}
