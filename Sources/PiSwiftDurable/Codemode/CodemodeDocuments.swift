import PiSwiftChord

/// The saved start data and final result of one code mode call.
public let CodemodeRunDoc = try! TaskDocToken<JSONObject>(kind: "pi.codemode.run", version: 1, initial: { [:] })
/// Results in delivery order and the number of calls made after each result.
public let CodemodeJournalDoc = try! TaskDocToken<JSONObject>(kind: "pi.codemode.journal", version: 1, initial: { ["entries": []] })
/// Saved script values. Forks copy the values at their entry boundary.
public let CodemodeStoreDoc = try! RewindableConversationDocToken<JSONObject>(kind: "pi.codemode.store", version: 1, fork: .asOf, initial: { ["values": [:]] }, checkpointWhen: { _, _, info in info.deltasSinceBase >= 64 })

/// A group of tools with a common name prefix. The longest prefix wins.
public struct CodemodeNamespace: Sendable, Equatable, Codable {
    public var name: String
    public var description: String?
    public var instructions: String?
    public var prefix: String
    public init(name: String, prefix: String, description: String? = nil, instructions: String? = nil) {
        self.name = name; self.prefix = prefix; self.description = description; self.instructions = instructions
    }
}

/// A nested tool call shown in the final code mode details.
public struct CodemodeNestedCall: Sendable, Equatable, Codable {
    public enum Status: String, Sendable, Codable { case running, ok, error, cancelled }
    public var id: Int
    public var name: String
    public var args: String
    public var status: Status
    public var durationMs: Int?
    public var error: String?
    public init(id: Int, name: String, args: String, status: Status, durationMs: Int? = nil, error: String? = nil) {
        self.id = id; self.name = name; self.args = args; self.status = status; self.durationMs = durationMs; self.error = error
    }
}

/// Final nested call details and the optional full-output file path.
public struct CodemodeToolDetails: Sendable, Equatable, Codable {
    public var calls: [CodemodeNestedCall]
    public var fullOutputPath: String?
    public init(calls: [CodemodeNestedCall], fullOutputPath: String? = nil) {
        self.calls = calls; self.fullOutputPath = fullOutputPath
    }
}

internal struct CodemodeStart: Sendable, Codable {
    struct Tool: Sendable, Codable {
        var name: String
        var jsName: String
        var description: String
        var structured: Bool?
        var hidden: Bool?
    }
    struct Namespace: Sendable, Codable {
        var name: String
        var description: String?
        var instructions: String?
        var tools: [String]
    }
    var version: Int
    var startedAt: Double
    var seed: UInt32
    var fingerprint: String?
    var deadline: Double?
    var tools: [Tool]
    var namespaces: [Namespace]
    var globals: [CodemodeDeclaredGlobal]
    var maxOutputTokens: Int
    var store: JSONObject
}
internal struct CodemodeJournalEntry: Sendable, Codable {
    struct Global: Sendable, Codable {
        var name: String
        var args: JSONValue?
        var outcome: CodemodeOutcome
        init(name: String, args: JSONValue?, outcome: CodemodeOutcome) {
            self.name = name; self.args = args; self.outcome = outcome
        }
        private enum CodingKeys: String, CodingKey { case name, args, outcome }
        init(from decoder: any Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            name = try fields.decode(String.self, forKey: .name)
            if fields.contains(.args) { args = .some(try fields.decode(JSONValue.self, forKey: .args)) }
            else { args = .none }
            outcome = try fields.decode(CodemodeOutcome.self, forKey: .outcome)
        }
        func encode(to encoder: any Encoder) throws {
            var fields = encoder.container(keyedBy: CodingKeys.self)
            try fields.encode(name, forKey: .name)
            if let args { try fields.encode(args, forKey: .args) }
            try fields.encode(outcome, forKey: .outcome)
        }
    }
    var id: Int
    var at: Double
    var issuedAfter: Int?
    var global: Global?
}
internal struct CodemodeJournal: Sendable, Codable {
    var entries: [CodemodeJournalEntry]
    var firstIssued: Int?
}
