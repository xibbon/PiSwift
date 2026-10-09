import PiSwiftCodingAgent
import PiSwiftDurable

/// Creates a registry with coding tools and pi's prompt sections.
public func createCodingRegistry(settingsManager: SettingsManager, cwd: String) throws -> Registry {
    let registry = createRegistry()
    try registry.install(try CodingTools)
    try registry.install(createPiPrompt(settingsManager: settingsManager, fallbackCwd: cwd))
    return registry
}

internal func createCodingRegistry(settingsManager: SettingsManager, cwd: String,
                                   agentDirectory: String) throws -> Registry {
    let registry = createRegistry()
    try registry.install(try CodingTools)
    try registry.install(createPiPrompt(settingsManager: settingsManager, fallbackCwd: cwd,
                                        agentDirectory: agentDirectory))
    return registry
}
