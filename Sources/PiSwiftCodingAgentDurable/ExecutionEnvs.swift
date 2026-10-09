import PiSwiftChord
import PiSwiftDurable
import Synchronization

/// Keeps one local execution environment for each working directory.
public final class ExecutionEnvs: Sendable {
    private let defaultCwd: String
    private let environments = Mutex<[String: LocalExecutionEnv]>([:])
    private let clean: @Sendable (LocalExecutionEnv, ChordContext) async -> Void

    /// Creates an environment pool with the supplied default directory.
    public init(defaultCwd: String) {
        self.defaultCwd = defaultCwd
        clean = { environment, context in await environment.cleanup(context: context) }
    }

    internal init(defaultCwd: String,
                  cleanup: @escaping @Sendable (LocalExecutionEnv, ChordContext) async -> Void) {
        self.defaultCwd = defaultCwd
        clean = cleanup
    }

    /// Uses the target directory, or the default when the target has no directory.
    public func env(_ target: EnvTarget) -> LocalExecutionEnv {
        let cwd = target.cwd ?? defaultCwd
        return environments.withLock { environments in
            if let found = environments[cwd] { return found }
            let environment = LocalExecutionEnv(cwd: cwd)
            environments[cwd] = environment
            return environment
        }
    }

    /// The factory supplied to `HarnessOptions`.
    public var factory: HarnessEnvFactory {
        { target, _ in self.env(target) }
    }

    /// Removes the current pool and cleans each environment once.
    /// Environments created during cleanup belong to the next pool.
    public func cleanup(context: ChordContext) async {
        let current = environments.withLock { environments in
            let current = Array(environments.values)
            environments.removeAll()
            return current
        }
        for environment in current { await clean(environment, context) }
    }
}
