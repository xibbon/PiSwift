import Foundation

/// Replace the leading home directory with `~` for display.
public func shortenHomePath(_ path: String, homeDir: String = getHomeDir()) -> String {
    guard !homeDir.isEmpty else { return path }
    #if os(Windows)
    let absolute = path.hasPrefix("\\\\") || path.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil
    let separator = "\\"
    #else
    let absolute = path.hasPrefix("/")
    let separator = "/"
    #endif
    guard absolute else { return path }
    let normalizedHome = URL(fileURLWithPath: homeDir).standardized.path
    let normalizedPath = URL(fileURLWithPath: path).standardized.path
    #if os(Windows)
    let homeKey = normalizedHome.lowercased()
    let pathKey = normalizedPath.lowercased()
    #else
    let homeKey = normalizedHome
    let pathKey = normalizedPath
    #endif
    if pathKey == homeKey { return "~" }
    let boundary = homeKey.hasSuffix(separator) ? homeKey : homeKey + separator
    guard pathKey.hasPrefix(boundary) else { return path }
    let relative = normalizedPath.dropFirst(boundary.count)
    return "~\(separator)\(relative)"
}
