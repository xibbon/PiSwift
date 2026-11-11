import Foundation
import CoreFoundation

/// The validated transport and original fields. Unknown application fields are retained.
public struct McpValidatedServerConfig {
    public enum Kind { case http, stdio }
    public let kind: Kind
    public let fields: [String: Any]
}

public enum McpServerConfigResult {
    case http(McpValidatedServerConfig)
    case stdio(McpValidatedServerConfig)
    case invalid(String)
}

private func isMcpBoolean(_ value: Any) -> Bool {
    guard let number = value as? NSNumber else { return false }
    return CFGetTypeID(number) == CFBooleanGetTypeID()
}

private func isMcpNumber(_ value: Any) -> Bool {
    guard let number = value as? NSNumber else { return false }
    return CFGetTypeID(number) != CFBooleanGetTypeID()
}

private func isMcpStringMap(_ value: Any) -> Bool {
    guard let map = value as? [String: Any] else { return false }
    return map.values.allSatisfy { $0 is String }
}

private func isLoopbackRedirectURI(_ text: String) -> Bool {
    guard let url = URLComponents(string: text), url.scheme == "http",
          let host = url.host?.lowercased(),
          ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host),
          url.query == nil, url.fragment == nil else { return false }
    return true
}

private func secureOrLoopback(_ text: String) -> Bool {
    guard let url = URLComponents(string: text), let host = url.host?.lowercased(), !host.isEmpty else { return false }
    return url.scheme?.lowercased() == "https" ||
        (url.scheme?.lowercased() == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host))
}

/// Validate the shared MCP server fields. The caller validates its own fields separately.
public func validateMcpServerConfig(
    name: String, value: Any,
    checkMetadataDocumentCallback: ((String?) -> String?)? = nil
) -> McpServerConfigResult {
    func invalid(_ text: String) -> McpServerConfigResult { .invalid(text) }
    guard name.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
        return invalid("invalid server name \"\(name)\" (use letters, digits, \"_\" and \"-\")")
    }
    guard let fields = value as? [String: Any] else { return invalid("server \"\(name)\" must be an object") }
    let prefix = "server \"\(name)\": "
    if let enabled = fields["enabled"], !isMcpBoolean(enabled) { return invalid(prefix + "enabled must be a boolean") }
    if let description = fields["description"], !(description is String) { return invalid(prefix + "description must be a string") }
    if let timeout = fields["timeout"], (!isMcpNumber(timeout) || (timeout as? NSNumber)?.doubleValue ?? 0 <= 0) {
        return invalid(prefix + "timeout must be a positive number of seconds")
    }
    let type = fields["type"] as? String
    if type == "sse" { return invalid(prefix + "legacy SSE transport is not supported; use the streamable HTTP URL") }
    if let url = fields["url"] as? String, type == nil || type == "http" || type == "streamable-http" {
        guard let parsed = URL(string: url), ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""), parsed.host != nil else {
            return invalid(prefix + "url must be an http or https URL")
        }
        if let headers = fields["headers"], !isMcpStringMap(headers) { return invalid(prefix + "headers must map names to strings") }
        if let oauth = fields["oauth"] {
            guard let oauth = oauth as? [String: Any] else { return invalid(prefix + "oauth must be an object") }
            for key in ["clientId", "clientSecret"] {
                if let candidate = oauth[key], !(candidate is String) { return invalid(prefix + "oauth.\(key) must be a string") }
            }
            if let port = oauth["callbackPort"] {
                guard isMcpNumber(port), let number = port as? NSNumber,
                      number.doubleValue.rounded() == number.doubleValue, (1...65535).contains(number.intValue) else {
                    return invalid(prefix + "oauth.callbackPort must be a port number")
                }
            }
            if let redirect = oauth["callbackUrl"] {
                guard let redirect = redirect as? String, isLoopbackRedirectURI(redirect) else {
                    return invalid(prefix + "oauth.callbackUrl must be an http URI on localhost, 127.0.0.1, or [::1] without query or fragment")
                }
                if let uriPort = URLComponents(string: redirect)?.port,
                   let configured = (oauth["callbackPort"] as? NSNumber)?.intValue, uriPort != configured {
                    return invalid(prefix + "oauth.callbackUrl and oauth.callbackPort name different ports")
                }
            }
            if let scope = oauth["scope"], !(scope is String) { return invalid(prefix + "oauth.scope must be a string") }
            if let clientName = oauth["clientName"],
               !(clientName is String) || (clientName as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                return invalid(prefix + "oauth.clientName must be a non-empty string")
            }
            if let registration = oauth["clientRegistration"] {
                // Unlike upstream config.ts:204-220, this port has no per-server Client ID Metadata Documents.
                // Its "auto" mode therefore has no document to select.
                guard let registration = registration as? String, ["dcr", "cimd"].contains(registration) else {
                    return invalid(prefix + "oauth.clientRegistration must be \"dcr\" or \"cimd\"")
                }
                if registration == "cimd" {
                    if oauth["clientId"] != nil || oauth["clientName"] != nil {
                        return invalid(prefix + "oauth.clientRegistration \"cimd\" cannot be combined with oauth.clientId or oauth.clientName")
                    }
                    guard let checkMetadataDocumentCallback else {
                        return invalid(prefix + "oauth.clientRegistration \"cimd\" is not supported: there are no Client ID Metadata Documents")
                    }
                    if let error = checkMetadataDocumentCallback(oauth["callbackUrl"] as? String) { return invalid(prefix + error) }
                }
            }
            if let metadataURL = oauth["authServerMetadataUrl"] {
                guard let metadataURL = metadataURL as? String, secureOrLoopback(metadataURL) else {
                    return invalid(prefix + "oauth.authServerMetadataUrl must be an https URL, or http on localhost, 127.0.0.1, or [::1]")
                }
            }
        }
        return .http(McpValidatedServerConfig(kind: .http, fields: fields))
    }
    if fields["command"] is String, type == nil || type == "stdio" {
        if let args = fields["args"], !(args is [String]) { return invalid(prefix + "args must be an array of strings") }
        if let env = fields["env"], !isMcpStringMap(env) { return invalid(prefix + "env must map names to strings") }
        if let cwd = fields["cwd"], !(cwd is String) { return invalid(prefix + "cwd must be a string") }
        return .stdio(McpValidatedServerConfig(kind: .stdio, fields: fields))
    }
    return invalid("server \"\(name)\" needs either \"command\" (stdio) or \"url\" (streamable HTTP)")
}

public func isMcpServerOverride(_ fields: [String: Any]) -> Bool {
    fields["command"] == nil && fields["url"] == nil && fields["type"] == nil
}
