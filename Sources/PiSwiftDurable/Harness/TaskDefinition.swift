import Foundation
import PiSwiftChord

/// Checkpoints encode a JSON object with a string `phase` member.
public protocol TaskCheckpoint: Codable, Sendable {
    associatedtype Phase: RawRepresentable & Codable & Sendable where Phase.RawValue == String
    var phase: Phase { get }
}

public struct NoTaskHooks: Sendable { public init() {} }

public struct TaskDefinitionError: Error, Sendable, Equatable, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// The decoded record passed to a phase or abort handler.
public struct RunningTask<Input: Codable & Sendable, Checkpoint: TaskCheckpoint>: Sendable {
    public let record: TaskRecord
    public let input: Input
    public let checkpoint: Checkpoint
    public var id: TaskID { record.id }
    public var conversationId: ConversationID { record.conversationId }
    public var abortRequested: Bool { record.abortRequested }
    public init(_ record: TaskRecord) throws {
        guard case .running(let checkpoint, _) = record.state else {
            throw TaskDefinitionError("Task \(record.id.rawValue) is not running")
        }
        self.record = record
        input = try record.input.decode(Input.self)
        self.checkpoint = try checkpoint.decode(Checkpoint.self)
    }
}

/// Use one switch over `task.checkpoint.phase` to dispatch all phases.
public struct TaskDefinition<Input: Codable & Sendable, Checkpoint: TaskCheckpoint,
                             Result: Codable & Sendable, Hooks: Sendable>: Sendable {
    public typealias Handler = @Sendable (RunningTask<Input, Checkpoint>, TaskRuntime, ChordContext) async throws -> Void
    public let identity: UUID
    public let kind: TaskKind<Input, Checkpoint>
    public let phase: Handler
    public let abort: Handler
    public let migrate: (@Sendable (JSONValue, JSONValue, Double) throws -> (input: Input, checkpoint: Checkpoint))?
    public var name: String { kind.name }
    public var version: Double { kind.version }

    public init(name: String, version: Double,
                initial: @escaping @Sendable (Input) throws -> Checkpoint,
                phase: @escaping Handler, abort: @escaping Handler,
                migrate: (@Sendable (JSONValue, JSONValue, Double) throws -> (input: Input, checkpoint: Checkpoint))? = nil) {
        identity = UUID()
        kind = TaskKind(name: name, version: version, initial: { input in
            let checkpoint = try initial(input)
            _ = try encodeTaskCheckpoint(checkpoint)
            return checkpoint
        })
        self.phase = phase; self.abort = abort; self.migrate = migrate
    }
    public func eraseToAnyTaskDefinition() -> AnyTaskDefinition { AnyTaskDefinition(self) }
    public func running(_ checkpoint: Checkpoint) throws -> TaskState {
        .running(checkpoint: try encodeTaskCheckpoint(checkpoint))
    }
    public func waiting(_ checkpoint: Checkpoint, on: [TaskID], policy: JoinPolicy) throws -> TaskState {
        .waiting(checkpoint: try encodeTaskCheckpoint(checkpoint), on: on, policy: policy)
    }
    public func completed(_ result: Result) throws -> TaskState {
        .terminal(outcome: .completed(result: try JSONValue(encoding: result)))
    }
}

public func defineTask<Input, Checkpoint, Result, Hooks>(
    _ definition: TaskDefinition<Input, Checkpoint, Result, Hooks>
) -> TaskDefinition<Input, Checkpoint, Result, Hooks> { definition }

/// JSON boundary used by the scheduler and the registry.
public struct AnyTaskDefinition: Sendable {
    public let identity: UUID
    public let name: String
    public let version: Double
    public let initial: @Sendable (JSONValue) throws -> JSONValue
    public let migrate: (@Sendable (JSONValue, JSONValue, Double) throws -> (input: JSONValue, checkpoint: JSONValue))?
    public let run: @Sendable (TaskRecord, TaskRuntime, ChordContext) async throws -> Void
    public let abort: @Sendable (TaskRecord, TaskRuntime, ChordContext) async throws -> Void

    public init<Input, Checkpoint, Result, Hooks>(_ definition: TaskDefinition<Input, Checkpoint, Result, Hooks>) {
        identity = definition.identity; name = definition.name; version = definition.version
        initial = { try encodeTaskCheckpoint(definition.kind.initial($0.decode(Input.self))) }
        if let migrate = definition.migrate {
            self.migrate = { input, checkpoint, version in
                let converted = try migrate(input, checkpoint, version)
                return (try JSONValue(encoding: converted.input), try encodeTaskCheckpoint(converted.checkpoint))
            }
        } else { migrate = nil }
        run = { record, runtime, context in try await definition.phase(RunningTask(record), runtime, context) }
        abort = { record, runtime, context in try await definition.abort(RunningTask(record), runtime, context) }
    }

    /// The built-in run tasks every registry holds, in upstream order (`registry.ts:10`).
    public static let builtins: [AnyTaskDefinition] = [
        generationTask.eraseToAnyTaskDefinition(), toolTask.eraseToAnyTaskDefinition(),
        compactionTask.eraseToAnyTaskDefinition(),
    ]
}

func encodeTaskCheckpoint<Checkpoint: TaskCheckpoint>(_ checkpoint: Checkpoint) throws -> JSONValue {
    let value = try JSONValue(encoding: checkpoint)
    guard case .object(let object) = value, object["phase"] == .string(checkpoint.phase.rawValue) else {
        throw TaskDefinitionError("Task checkpoint must encode a JSON object with its phase")
    }
    return value
}

public func hook<Input, Checkpoint, Result, Hooks>(
    _ task: TaskDefinition<Input, Checkpoint, Result, Hooks>, handlers: Hooks
) -> HookRegistration { HookRegistration(task: task.name, handlers: handlers) }

extension Transaction {
    public func createTask<Input, Checkpoint, Result, Hooks>(
        _ task: TaskDefinition<Input, Checkpoint, Result, Hooks>, input: Input, options: TaskOptions
    ) async throws -> TaskID { try await createTask(task.kind, input: input, options: options) }
}
