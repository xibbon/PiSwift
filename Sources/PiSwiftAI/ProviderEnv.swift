import Foundation

/// Scoped nonempty values take priority over the process environment.
public func getProviderEnvValue(_ name: String, env: [String: String]? = nil) -> String? {
    if let value = env?[name], !value.isEmpty { return value }
    if let value = ProcessInfo.processInfo.environment[name], !value.isEmpty { return value }
    return nil
}

public func providerEnvironment(_ env: [String: String]? = nil) -> [String: String] {
    ProcessInfo.processInfo.environment.filter { !$0.value.isEmpty }.merging((env ?? [:]).filter { !$0.value.isEmpty }) { _, scoped in scoped }
}
