import Foundation

/// OpenCode routes requests by conversation, including requests without prompt caching.
/// A caller's header (even an explicit nil) takes precedence regardless of case.
func openCodeSessionHeaders(model: Model, sessionId: String?, headers: ProviderHeaders?) -> ProviderHeaders? {
    guard model.provider == KnownProvider.opencode.rawValue || model.provider == KnownProvider.opencodeGo.rawValue,
          let sessionId, !sessionId.isEmpty else { return headers }
    let name = "x-opencode-session"
    guard !((headers ?? [:]).keys.contains { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return headers }
    var result = headers ?? [:]
    result[name] = sessionId
    return result
}
