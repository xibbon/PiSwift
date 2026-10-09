import Foundation
import PiSwiftChord

/// Checkpoints encode a JSON object with a string `phase` member.
public protocol TaskCheckpoint: Codable, Sendable {
    /// The phase type whose string raw value is stored in the checkpoint.
    associatedtype Phase: RawRepresentable & Codable & Sendable where Phase.RawValue == String
    /// The persisted task phase or its execution callback.
    var phase: Phase { get }
}

/// The hook type for an application task with no hook callbacks.
public struct NoTaskHooks: Sendable {
    /// Creates the empty hook value for an application task.
    public init() {}
}

/// A task definition or encoded checkpoint violates the harness contract.
public struct TaskDefinitionError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Text that describes this value or error to the caller.
    public let description: String
    /// Stores the task definition error message.
    public init(_ description: String) { self.description = description }
}

/// The decoded record passed to a phase or abort handler.
public struct RunningTask<Input: Codable & Sendable, Checkpoint: TaskCheckpoint>: Sendable {
    /// The durable record from which this typed value is derived.
    public let record: TaskRecord
    /// The decoded or saved input supplied when the task was created.
    public let input: Input
    /// The saved state used to resume the task.
    public let checkpoint: Checkpoint
    /// The stable identifier of this record or handle.
    public var id: TaskID { record.id }
    /// The conversation that owns or is addressed by this value.
    public var conversationId: ConversationID { record.conversationId }
    /// Whether an abort request has been saved for this task.
    public var abortRequested: Bool { record.abortRequested }
    /// Checks that the record is running, then decodes its input and checkpoint.
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
    /// A phase or abort callback bound to a task record and its runtime.
    public typealias Handler = @Sendable (RunningTask<Input, Checkpoint>, TaskRuntime, ChordContext) async throws -> Void
    /// The in-process identity used to detect a replaced task definition.
    public let identity: UUID
    /// The typed task kind used to encode input and create initial checkpoints.
    public let kind: TaskKind<Input, Checkpoint>
    /// Executes the handler for the current checkpoint phase.
    public let phase: Handler
    /// The callback that handles a durable abort request.
    public let abort: Handler
    /// Converts stored input or checkpoint state from an earlier definition version.
    public let migrate: (@Sendable (JSONValue, JSONValue, Double) throws -> (input: Input, checkpoint: Checkpoint))?
    /// The stable name used to resolve this definition in the registry.
    public var name: String { kind.name }
    /// The stored schema or task definition version.
    public var version: Double { kind.version }

    /// Defines typed task initialization, phase execution, cancellation, and optional migration.
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
    /// Creates the JSON task boundary used by the registry and scheduler.
    public func eraseToAnyTaskDefinition() -> AnyTaskDefinition { AnyTaskDefinition(self) }
    /// Creates a running task state from the typed checkpoint.
    public func running(_ checkpoint: Checkpoint) throws -> TaskState {
        .running(checkpoint: try encodeTaskCheckpoint(checkpoint))
    }
    /// Creates a waiting task state with dependency IDs and a join policy.
    public func waiting(_ checkpoint: Checkpoint, on: [TaskID], policy: JoinPolicy) throws -> TaskState {
        .waiting(checkpoint: try encodeTaskCheckpoint(checkpoint), on: on, policy: policy)
    }
    /// Creates a completed terminal task state with a JSON-encoded result.
    public func completed(_ result: Result) throws -> TaskState {
        .terminal(outcome: .completed(result: try JSONValue(encoding: result)))
    }
}

/// Returns the typed task definition for use in host registration.
public func defineTask<Input, Checkpoint, Result, Hooks>(
    _ definition: TaskDefinition<Input, Checkpoint, Result, Hooks>
) -> TaskDefinition<Input, Checkpoint, Result, Hooks> { definition }

/// JSON boundary used by the scheduler and the registry.
public struct AnyTaskDefinition: Sendable {
    /// The in-process identity used to detect a replaced task definition.
    public let identity: UUID
    /// The stable name used to resolve this definition in the registry.
    public let name: String
    /// The stored schema or task definition version.
    public let version: Double
    /// Creates the encoded initial checkpoint from task input.
    public let initial: @Sendable (JSONValue) throws -> JSONValue
    /// Converts stored input or checkpoint state from an earlier definition version.
    public let migrate: (@Sendable (JSONValue, JSONValue, Double) throws -> (input: JSONValue, checkpoint: JSONValue))?
    /// Invokes the typed phase handler after decoding the stored input and checkpoint.
    public let run: @Sendable (TaskRecord, TaskRuntime, ChordContext) async throws -> Void
    /// Invokes the typed abort handler after decoding the stored input and checkpoint.
    public let abort: @Sendable (TaskRecord, TaskRuntime, ChordContext) async throws -> Void

    /// Adapts a typed definition to the JSON boundary used by the scheduler.
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

/// Registers callbacks for the selected task kind.
public func hook<Input, Checkpoint, Result, Hooks>(
    _ task: TaskDefinition<Input, Checkpoint, Result, Hooks>, handlers: Hooks
) -> HookRegistration { HookRegistration(task: task.name, handlers: handlers) }

extension Transaction {
    /// Creates a typed task and stores its encoded input and initial checkpoint.
    public func createTask<Input, Checkpoint, Result, Hooks>(
        _ task: TaskDefinition<Input, Checkpoint, Result, Hooks>, input: Input, options: TaskOptions
    ) async throws -> TaskID { try await createTask(task.kind, input: input, options: options) }
}
