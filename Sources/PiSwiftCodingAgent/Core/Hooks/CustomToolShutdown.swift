import Foundation
import PiSwiftAI

/// The SDK creates custom-tool contexts from the same SessionManager as HookRunner.
/// Keep the host request handler scoped to that manager and remove it on disposal.
private let customToolShutdownHandlers = LockedState<[ObjectIdentifier: HookShutdownHandler]>([:])

func installCustomToolShutdownHandler(for manager: SessionManager, _ handler: @escaping HookShutdownHandler) {
    customToolShutdownHandlers.withLock { $0[ObjectIdentifier(manager)] = handler }
}

func removeCustomToolShutdownHandler(for manager: SessionManager) {
    customToolShutdownHandlers.withLock { $0.removeValue(forKey: ObjectIdentifier(manager)) }
}

public extension CustomToolContext {
    /// Ask the host to shut down. The default is a no-op until a host installs a handler.
    func shutdown() {
        let handler = customToolShutdownHandlers.withLock { $0[ObjectIdentifier(sessionManager)] }
        handler?()
    }
}
