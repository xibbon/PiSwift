import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum McpOAuthDiscovery {
    public static func parseWWWAuthenticate(_ header: String?) -> McpOAuthChallenge {
        guard let header,
              let scheme = header.split(whereSeparator: { $0.isWhitespace }).first?.lowercased(),
              scheme == "bearer" || scheme == "dpop" else { return McpOAuthChallenge() }
        func field(_ name: String) -> String? {
            let pattern = "(?:^|[,\\s])\(NSRegularExpression.escapedPattern(for: name))=(?:\"([^\"]*)\"|([^\\s,]+))"
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = expression.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)) else { return nil }
            for index in [1, 2] where match.range(at: index).location != NSNotFound {
                if let range = Range(match.range(at: index), in: header), !header[range].isEmpty { return String(header[range]) }
            }
            return nil
        }
        return McpOAuthChallenge(
            resourceMetadataURL: field("resource_metadata").flatMap(URL.init(string:)),
            scope: field("scope"), error: field("error"), errorDescription: field("error_description")
        )
    }

    public static func protectedResourceMetadata(
        serverURL: URL, resourceMetadataURL: URL? = nil,
        http: any McpOAuthHTTPClient = McpURLSessionOAuthHTTPClient(),
        protocolVersion: String = LATEST_PROTOCOL_VERSION
    ) async throws -> McpOAuthProtectedResourceMetadata {
        let origin = try originURL(serverURL)
        let path = trimmedPath(serverURL.path)
        let first = resourceMetadataURL ?? origin.appending(path: "/.well-known/oauth-protected-resource\(path)")
        var (data, response) = try await get(first, http: http, protocolVersion: protocolVersion)
        if resourceMetadataURL == nil && !path.isEmpty && isDiscoveryMiss(response.statusCode) {
            (data, response) = try await get(origin.appending(path: "/.well-known/oauth-protected-resource"), http: http, protocolVersion: protocolVersion)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw McpOAuthError.httpStatus(response.statusCode, String(decoding: data, as: UTF8.self))
        }
        return try decode(McpOAuthProtectedResourceMetadata.self, from: data, name: "protected resource metadata")
    }

    public static func authorizationServerDiscoveryURLs(_ issuer: URL) throws -> [URL] {
        let origin = try originURL(issuer)
        let path = trimmedPath(issuer.path)
        var urls = [
            origin.appending(path: "/.well-known/oauth-authorization-server\(path)"),
            origin.appending(path: "/.well-known/openid-configuration\(path)"),
        ]
        if !path.isEmpty { urls.append(origin.appending(path: "\(path)/.well-known/openid-configuration")) }
        return urls
    }

    public static func authorizationServerMetadata(
        issuer: URL, http: any McpOAuthHTTPClient = McpURLSessionOAuthHTTPClient(),
        protocolVersion: String = LATEST_PROTOCOL_VERSION, skipIssuerValidation: Bool = false
    ) async throws -> McpOAuthAuthorizationServerMetadata? {
        for url in try authorizationServerDiscoveryURLs(issuer) {
            let (data, response) = try await get(url, http: http, protocolVersion: protocolVersion)
            guard (200..<300).contains(response.statusCode) else {
                if isDiscoveryMiss(response.statusCode) { continue }
                throw McpOAuthError.httpStatus(response.statusCode, "loading authorization server metadata from \(url)")
            }
            let metadata = try decode(McpOAuthAuthorizationServerMetadata.self, from: data, name: "authorization server metadata")
            if !skipIssuerValidation && metadata.issuer.trimmingCharacters(in: CharacterSet(charactersIn: "/")) != issuer.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
                throw McpOAuthError.issuerMismatch(expected: issuer.absoluteString, received: metadata.issuer)
            }
            return metadata
        }
        return nil
    }

    public static func serverInfo(
        serverURL: URL, resourceMetadataURL: URL? = nil, authorizationServerMetadataURL: URL? = nil,
        http: any McpOAuthHTTPClient = McpURLSessionOAuthHTTPClient(),
        skipIssuerValidation: Bool = false
    ) async throws -> McpOAuthServerInfo {
        let resource: McpOAuthProtectedResourceMetadata?
        do {
            resource = try await protectedResourceMetadata(serverURL: serverURL, resourceMetadataURL: resourceMetadataURL, http: http)
        } catch is McpOAuthError {
            // Upstream treats failed protected-resource discovery as absence, then tries the server origin.
            resource = nil
        }
        if let url = authorizationServerMetadataURL {
            let (data, response) = try await get(url, http: http, protocolVersion: LATEST_PROTOCOL_VERSION)
            guard (200..<300).contains(response.statusCode) else {
                throw McpOAuthError.httpStatus(response.statusCode, "loading authorization server metadata from \(url)")
            }
            let metadata = try decode(McpOAuthAuthorizationServerMetadata.self, from: data, name: "authorization server metadata")
            guard let issuer = URL(string: metadata.issuer) else { throw McpOAuthError.invalidMetadata("issuer") }
            return McpOAuthServerInfo(authorizationServerURL: issuer,
                authorizationServerMetadata: metadata, resourceMetadata: resource)
        }
        let authorizationServerURL = try resource?.authorizationServers?.first.flatMap(URL.init(string:)) ?? originURL(serverURL)
        return McpOAuthServerInfo(
            authorizationServerURL: authorizationServerURL,
            authorizationServerMetadata: try await authorizationServerMetadata(
                issuer: authorizationServerURL, http: http, skipIssuerValidation: skipIssuerValidation),
            resourceMetadata: resource
        )
    }

    public static func selectResource(serverURL: URL, metadata: McpOAuthProtectedResourceMetadata?) throws -> String? {
        guard let metadata else { return nil }
        guard let configured = URL(string: metadata.resource),
              let serverHost = serverURL.host, serverHost == configured.host,
              serverURL.scheme == configured.scheme, serverURL.port == configured.port else {
            throw McpOAuthError.invalidMetadata("protected resource does not match MCP server")
        }
        let requestedPath = serverURL.path.hasSuffix("/") ? serverURL.path : serverURL.path + "/"
        let configuredPath = configured.path.hasSuffix("/") ? configured.path : configured.path + "/"
        guard requestedPath.hasPrefix(configuredPath) else {
            throw McpOAuthError.invalidMetadata("protected resource does not match MCP server")
        }
        return metadata.resource
    }

    private static func get(_ url: URL, http: any McpOAuthHTTPClient, protocolVersion: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        return try await http.send(request)
    }

    private static func isDiscoveryMiss(_ status: Int) -> Bool { (400..<500).contains(status) || status == 502 }
    private static func trimmedPath(_ path: String) -> String {
        if path == "/" { return "" }
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private static func originURL(_ url: URL) throws -> URL {
        guard let scheme = url.scheme, let host = url.host,
              let origin = URL(string: "\(scheme)://\(host)\(url.port.map { ":\($0)" } ?? "")") else {
            throw McpOAuthError.invalidMetadata("server URL")
        }
        return origin
    }

    static func validateURL(_ value: String, field: String) throws {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              !["javascript", "data", "vbscript"].contains(scheme), url.host != nil else {
            throw McpOAuthError.invalidMetadata(field)
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data, name: String) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw McpOAuthError.invalidMetadata(name) }
    }
}
