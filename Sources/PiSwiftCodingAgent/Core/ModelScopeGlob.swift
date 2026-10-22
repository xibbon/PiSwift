import Darwin
import Foundation

/// Match model scope paths without changing the shared file-glob rules.
func matchesModelScopeGlob(_ path: String, _ pattern: String) -> Bool {
    if let expanded = expandScopeBraces(pattern) {
        return expanded.contains { matchesModelScopeGlob(path, $0) }
    }
    let pathParts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    let patternParts = pattern.split(separator: "/", omittingEmptySubsequences: false).map(String.init)

    func match(_ pathIndex: Int, _ patternIndex: Int) -> Bool {
        guard patternIndex < patternParts.count else { return pathIndex == pathParts.count }
        let part = patternParts[patternIndex]
        if part == "**" {
            if match(pathIndex, patternIndex + 1) { return true }
            var index = pathIndex
            while index < pathParts.count, !pathParts[index].hasPrefix(".") {
                index += 1
                if match(index, patternIndex + 1) { return true }
            }
            return false
        }
        guard pathIndex < pathParts.count else { return false }
        let matches = part.withCString { patternPointer in
            pathParts[pathIndex].withCString { pathPointer in
                fnmatch(patternPointer, pathPointer, FNM_CASEFOLD | FNM_PERIOD) == 0
            }
        }
        return matches && match(pathIndex + 1, patternIndex + 1)
    }
    return match(0, 0)
}

private func expandScopeBraces(_ pattern: String) -> [String]? {
    var depth = 0
    var start: String.Index?
    var separators: [String.Index] = []
    var escaped = false
    for index in pattern.indices {
        let character = pattern[index]
        if escaped {
            escaped = false
            continue
        }
        if character == "\\" {
            escaped = true
            continue
        }
        if character == "{" {
            if depth == 0 { start = index }
            depth += 1
        } else if character == ",", depth == 1 {
            separators.append(index)
        } else if character == "}", depth > 0 {
            depth -= 1
            if depth == 0, let start, !separators.isEmpty {
                let prefix = String(pattern[..<start])
                let suffix = String(pattern[pattern.index(after: index)...])
                var partStart = pattern.index(after: start)
                return (separators + [index]).map { end in
                    defer { partStart = pattern.index(after: end) }
                    return prefix + pattern[partStart..<end] + suffix
                }
            }
        }
    }
    return nil
}
