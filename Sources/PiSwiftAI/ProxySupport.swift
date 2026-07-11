import Foundation

private let proxySessionState = LockedState<URLSession?>(nil)

func proxySession(for url: URL?) -> URLSession {
    let env = ProcessInfo.processInfo.environment
    guard let proxyConfig = buildProxyConfig(env: env) else { return URLSession.shared }
    let noProxy = parseNoProxy(env: env)
    if shouldBypassProxy(host: url?.host, noProxy: noProxy) {
        return URLSession.shared
    }

    return proxySessionState.withLock { session in
        if let session { return session }
        let config = URLSessionConfiguration.default
        config.connectionProxyDictionary = proxyConfig
        let created = URLSession(configuration: config)
        session = created
        return created
    }
}

private func buildProxyConfig(env: [String: String]) -> [AnyHashable: Any]? {
    #if os(macOS)
    let allProxy = env["ALL_PROXY"] ?? env["all_proxy"]
    let httpProxy = env["HTTP_PROXY"] ?? env["http_proxy"] ?? allProxy
    let httpsProxy = env["HTTPS_PROXY"] ?? env["https_proxy"] ?? httpProxy ?? allProxy
    guard httpProxy != nil || httpsProxy != nil else { return nil }

    var config: [AnyHashable: Any] = [:]
    if let httpProxy, let parsed = parseProxy(httpProxy) {
        config[kCFNetworkProxiesHTTPEnable as String] = 1
        config[kCFNetworkProxiesHTTPProxy as String] = parsed.host
        config[kCFNetworkProxiesHTTPPort as String] = parsed.port
    }
    if let httpsProxy, let parsed = parseProxy(httpsProxy) {
        config[kCFNetworkProxiesHTTPSEnable as String] = 1
        config[kCFNetworkProxiesHTTPSProxy as String] = parsed.host
        config[kCFNetworkProxiesHTTPSPort as String] = parsed.port
    }
    return config.isEmpty ? nil : config
    #else
    // Environment-variable proxy configuration is a desktop concept; iOS apps
    // use the system-managed proxy settings through URLSession.shared.
    return nil
    #endif
}

#if os(macOS)
private func parseProxy(_ value: String) -> (host: String, port: Int)? {
    var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return nil }
    if !trimmed.contains("://") {
        trimmed = "http://\(trimmed)"
    }
    guard let url = URL(string: trimmed), let host = url.host else { return nil }
    let port = url.port ?? (url.scheme == "https" ? 443 : 80)
    return (host, port)
}
#endif

private func parseNoProxy(env: [String: String]) -> [String] {
    let raw = env["NO_PROXY"] ?? env["no_proxy"] ?? ""
    return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
}

private func shouldBypassProxy(host: String?, noProxy: [String]) -> Bool {
    guard let host, !host.isEmpty else { return false }
    for entry in noProxy {
        if entry == "*" { return true }
        if host == entry { return true }
        if entry.hasPrefix("."), host.hasSuffix(entry) { return true }
        if host.hasSuffix(".\(entry)") { return true }
    }
    return false
}
