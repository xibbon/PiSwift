import Foundation

#if os(macOS)
import Network
#endif

private let proxySessionState = LockedState<[String: URLSession]>([:])

func proxySession(for url: URL?) -> URLSession {
    let env = ProcessInfo.processInfo.environment
    let noProxy = parseNoProxy(env: env)
    if shouldBypassProxy(host: url?.host, port: url?.port ?? (url?.scheme == "https" ? 443 : 80), noProxy: noProxy) {
        return URLSession.shared
    }
    #if os(macOS)
    guard let proxyURL = selectedProxyURL(for: url, env: env) else { return URLSession.shared }
    return proxySessionState.withLock { sessions in
        let key = proxyURL.absoluteString
        if let session = sessions[key] { return session }
        guard let session = makeHTTPConnectProxySession(proxyURL: proxyURL) else { return URLSession.shared }
        sessions[key] = session
        return session
    }
    #else
    // Mobile hosts use system-managed proxy settings.
    return URLSession.shared
    #endif
}

#if os(macOS)
func selectedProxyURL(for destination: URL?, env: [String: String]) -> URL? {
    let allProxy = env["ALL_PROXY"] ?? env["all_proxy"]
    let httpProxy = env["HTTP_PROXY"] ?? env["http_proxy"] ?? allProxy
    let httpsProxy = env["HTTPS_PROXY"] ?? env["https_proxy"] ?? httpProxy ?? allProxy
    guard var value = destination?.scheme?.lowercased() == "https" ? httpsProxy : httpProxy else { return nil }
    value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }
    if !value.contains("://") { value = "http://" + value }
    return URL(string: value)
}

/// Creates an explicit CONNECT proxy session, including for plain HTTP origins.
/// Accepts an injected proxy URL so hosts and tests need not change process environment.
func makeHTTPConnectProxySession(proxyURL: URL) -> URLSession? {
    guard let host = proxyURL.host,
          let rawPort = UInt16(exactly: proxyURL.port ?? (proxyURL.scheme?.lowercased() == "https" ? 443 : 80)),
          rawPort != 0, let port = NWEndpoint.Port(rawValue: rawPort) else { return nil }
    let tlsOptions: NWProtocolTLS.Options? = proxyURL.scheme?.lowercased() == "https" ? .init() : nil
    var proxy = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: NWEndpoint.Host(stripProxyBrackets(host)), port: port), tlsOptions: tlsOptions)
    proxy.allowFailover = false
    if let user = proxyURL.user {
        proxy.applyCredential(username: user.removingPercentEncoding ?? user,
                              password: proxyURL.password?.removingPercentEncoding ?? proxyURL.password ?? "")
    }
    let configuration = URLSessionConfiguration.default
    configuration.proxyConfigurations = [proxy]
    return URLSession(configuration: configuration)
}
#endif


func parseNoProxy(env: [String: String]) -> [String] {
    let raw = env["NO_PROXY"] ?? env["no_proxy"] ?? ""
    return raw.split { $0 == "," || $0.isWhitespace }.map(String.init)
}

private func stripProxyBrackets(_ host: String) -> String {
    host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
}

// Match JavaScript parseInt: accept the leading decimal part of a port.
private func parseNoProxyPort(_ text: Substring) -> Int? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let sign = trimmed.hasPrefix("-") ? "-" : ""
    let digits = trimmed.drop(while: { $0 == "+" || $0 == "-" }).prefix(while: { $0.isASCII && $0.isNumber })
    return digits.isEmpty ? nil : Int(sign + digits)
}

func parseNoProxyEntry(_ entry: String) -> (host: String, port: Int)? {
    let value = entry.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !value.isEmpty else { return nil }
    if value.hasPrefix("["), let close = value.firstIndex(of: "]") {
        let host = String(value[value.index(after: value.startIndex)..<close])
        let rest = value[value.index(after: close)...]
        return (host, rest.hasPrefix(":") ? parseNoProxyPort(rest.dropFirst()) ?? 0 : 0)
    }
    let colons = value.filter { $0 == ":" }.count
    if colons > 1 { return (value, 0) }
    if colons == 1, let colon = value.firstIndex(of: ":"), let port = parseNoProxyPort(value[value.index(after: colon)...]) {
        return (String(value[..<colon]), port)
    }
    return (value, 0)
}

func shouldBypassProxy(host: String?, port: Int = 0, noProxy: [String]) -> Bool {
    guard let host, !host.isEmpty else { return false }
    let target = stripProxyBrackets(host.lowercased())
    // Upstream recognizes the wildcard only when it is the complete NO_PROXY value.
    if noProxy == ["*"] { return true }
    for entry in noProxy {
        guard let parsed = parseNoProxyEntry(entry), parsed.port == 0 || parsed.port == port else { continue }
        var domain = stripProxyBrackets(parsed.host)
        if domain.hasPrefix("*.") { domain = String(domain.dropFirst(2)) }
        else if domain.hasPrefix(".") || domain.hasPrefix("*") { domain = String(domain.dropFirst()) }
        if !domain.isEmpty && (target == domain || target.hasSuffix("." + domain)) { return true }
    }
    return false
}
