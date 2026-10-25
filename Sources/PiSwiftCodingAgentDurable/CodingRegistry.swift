import PiSwiftCodingAgent
import PiSwiftDurable
import PiSwiftDurableJSC

/// A deferred tool setting names a tool that the host did not register.
public enum CodingRegistryError: Error, Sendable, Equatable, CustomStringConvertible {
    case unknownDeferredTool(String)

    public var description: String {
        switch self {
        case .unknownDeferredTool(let name): "Unknown durable deferred tool: \(name)"
        }
    }
}

/// Creates a registry with coding tools, code mode, and pi's prompt sections.
/// Supply a sandbox to own its lifetime. Close the Harness before the sandbox.
/// Unknown deferred names are reported once per registry through `onReport`.
public func createCodingRegistry(settingsManager: SettingsManager, cwd: String,
                                 sandbox: JSCCodemodeSandbox = JSCCodemodeSandbox(),
                                 onReport: @Sendable (any Error) -> Void = { _ in }) throws -> Registry {
    try codingRegistry(settingsManager: settingsManager, sandbox: sandbox, onReport: onReport,
        prompt: createPiPrompt(settingsManager: settingsManager, fallbackCwd: cwd))
}

internal func createCodingRegistry(settingsManager: SettingsManager, cwd: String,
                                   agentDirectory: String,
                                   sandbox: JSCCodemodeSandbox = JSCCodemodeSandbox(),
                                   onReport: @Sendable (any Error) -> Void = { _ in }) throws -> Registry {
    try codingRegistry(settingsManager: settingsManager, sandbox: sandbox, onReport: onReport,
        prompt: createPiPrompt(settingsManager: settingsManager, fallbackCwd: cwd,
                               agentDirectory: agentDirectory),
        additional: [try subagentExtension()])
}

private func codingRegistry(settingsManager: SettingsManager, sandbox: JSCCodemodeSandbox,
                            onReport: @Sendable (any Error) -> Void,
                            prompt: Extension, additional: [Extension] = []) throws -> Registry {
    let registry = createRegistry()
    var extensions = [try createCodingTools(images: NativeImageProcessor()), prompt,
                      try createCodemodeExtension(options: .init(sandbox: sandbox, models: true))] + additional
    let deferred = settingsManager.getDurableDeferredTools()
    if !deferred.isEmpty { extensions.append(try createToolSearchExtension()) }
    let requested = Set(deferred.map { Array($0.utf16) })
    let registered = Set(extensions.flatMap(\.tools).map { Array($0.name.utf16) })
    var reported = Set<[UInt16]>()
    for name in deferred where !registered.contains(Array(name.utf16)) {
        if reported.insert(Array(name.utf16)).inserted { onReport(CodingRegistryError.unknownDeferredTool(name)) }
    }
    for var item in extensions {
        for index in item.tools.indices where requested.contains(Array(item.tools[index].name.utf16)) {
            item.tools[index].deferred = true
        }
        try registry.install(item)
    }
    return registry
}
