import Foundation
import PiSwiftChord
import Synchronization

/// A tool suspension. The Harness stores its checkpoint and resumes the call after the wait ends.
public struct ToolPark: Sendable {
    /// The trigger selected by this park.
    public enum Trigger: Sendable {
        /// Sleep until a time or a signal arrives.
        case sleep(until: Double?, signals: [SignalKey])
        /// Wait for the selected tasks to settle.
        case wait(on: [TaskID], policy: JoinPolicy)
    }
    /// The saved tool value supplied on the next run or to cancel.
    public let checkpoint: JSONValue?
    /// The condition that wakes the tool.
    public let trigger: Trigger
    internal let identity: UUID

    /// Creates a time or signal sleep.
    public static func sleep(until: Double? = nil, signals: [SignalKey] = [], checkpoint: JSONValue? = nil) -> Self {
        Self(checkpoint: checkpoint, trigger: .sleep(until: until, signals: signals), identity: UUID())
    }
    /// Creates a task wait.
    public static func wait(on: [TaskID], policy: JoinPolicy, checkpoint: JSONValue? = nil) -> Self {
        Self(checkpoint: checkpoint, trigger: .wait(on: on, policy: policy), identity: UUID())
    }
}

/// Either a final tool result or a request to suspend the call.
public enum ToolExecutionOutcome: Sendable {
    /// Finish the call with this result.
    case result(ToolExecutionResult)
    /// Save the tool state and release its invocation until a wake.
    case park(ToolPark)
}

internal final class ToolBaseParks: Sendable {
    private let values = Mutex<Set<UUID>>([])
    func record(_ park: ToolPark) { values.withLock { $0.insert(park.identity) } }
    func contains(_ park: ToolPark) -> Bool { values.withLock { $0.contains(park.identity) } }
}

/// Records parks returned by a wrapped base during this invocation.
internal func wrapComposite(_ tool: ToolRegistration,
                            wrap: @Sendable (ToolRegistration) throws -> ToolRegistration) throws -> ToolRegistration {
    var base = tool
    if !tool.requiresBasePark {
        let execute = tool.executeOutcome
        base.executeOutcome = { args, api, context in
            let returned = try await execute(args, api, context)
            if case .park(let park) = returned { api.baseParks.record(park) }
            return returned
        }
    }
    var composite = try wrap(base)
    composite.requiresBasePark = true
    return composite
}
