import Foundation

public struct ChangelogEntry: Sendable {
    public var major: Int
    public var minor: Int
    public var patch: Int
    public var content: String

    public init(major: Int, minor: Int, patch: Int, content: String) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.content = content
    }
}

public func parseChangelog(_ changelogPath: String) -> [ChangelogEntry] {
    guard let content = try? String(contentsOfFile: changelogPath, encoding: .utf8) else {
        return []
    }

    let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
    var entries: [ChangelogEntry] = []
    var currentLines: [String] = []
    var currentVersion: (major: Int, minor: Int, patch: Int)?
    let regex = try? NSRegularExpression(pattern: "^##\\s+\\[?(\\d+)\\.(\\d+)\\.(\\d+)\\]?", options: [])

    for lineSub in lines {
        let line = String(lineSub)
        if line.hasPrefix("## ") {
            if let currentVersion, !currentLines.isEmpty {
                entries.append(ChangelogEntry(
                    major: currentVersion.major,
                    minor: currentVersion.minor,
                    patch: currentVersion.patch,
                    content: currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                ))
            }

            if let regex {
                let range = NSRange(location: 0, length: line.utf16.count)
                if let match = regex.firstMatch(in: line, options: [], range: range), match.numberOfRanges == 4,
                   let majorRange = Range(match.range(at: 1), in: line),
                   let minorRange = Range(match.range(at: 2), in: line),
                   let patchRange = Range(match.range(at: 3), in: line),
                   let major = Int(line[majorRange]),
                   let minor = Int(line[minorRange]),
                   let patch = Int(line[patchRange]) {
                    currentVersion = (major, minor, patch)
                    currentLines = [line]
                } else {
                    currentVersion = nil
                    currentLines = []
                }
            } else {
                currentVersion = nil
                currentLines = []
            }
        } else if currentVersion != nil {
            currentLines.append(line)
        }
    }

    if let currentVersion, !currentLines.isEmpty {
        entries.append(ChangelogEntry(
            major: currentVersion.major,
            minor: currentVersion.minor,
            patch: currentVersion.patch,
            content: currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        ))
    }

    return entries
}

public func compareVersions(_ lhs: ChangelogEntry, _ rhs: ChangelogEntry) -> Int {
    if lhs.major != rhs.major { return lhs.major - rhs.major }
    if lhs.minor != rhs.minor { return lhs.minor - rhs.minor }
    return lhs.patch - rhs.patch
}

public func getNewEntries(_ entries: [ChangelogEntry], lastVersion: String) -> [ChangelogEntry] {
    // v1.5.2 #11753: compare the leading release number, even for prereleases.
    let pattern = try! NSRegularExpression(pattern: #"^v?(\d+)\.(\d+)\.(\d+)"#)
    let version = lastVersion.trimmingCharacters(in: .whitespacesAndNewlines)
    let range = NSRange(location: 0, length: version.utf16.count)
    guard let match = pattern.firstMatch(in: version, range: range) else { return [] }
    let parts = (1...3).compactMap { index -> Int? in
        guard let range = Range(match.range(at: index), in: version) else { return nil }
        return Int(version[range])
    }
    let last = ChangelogEntry(
        major: parts.indices.contains(0) ? parts[0] : 0,
        minor: parts.indices.contains(1) ? parts[1] : 0,
        patch: parts.indices.contains(2) ? parts[2] : 0,
        content: ""
    )
    return entries.filter { compareVersions($0, last) > 0 }
}

public struct ExtensionChangelogUpdate: Sendable {
    public let name: String
    public let version: String
    public let markdown: String
}

/// Return package updates for a fresh session and record versions that were seen.
/// The host chooses how to show these entries and skips this call on resumed sessions.
public func getExtensionChangelogUpdates(
    extensions: [ResolvedResource],
    settings: SettingsManager
) -> [ExtensionChangelogUpdate] {
    var seen = Set<String>()
    var updates: [ExtensionChangelogUpdate] = []
    for entry in extensions {
        let metadata = entry.metadata
        guard metadata.origin == "package", let root = metadata.baseDir,
              let changelog = metadata.changelogPath else { continue }
        let source = String(data: try! JSONEncoder().encode(metadata.source), encoding: .utf8)!
        let scope = String(data: try! JSONEncoder().encode(metadata.scope), encoding: .utf8)!
        let key = "{\"source\":\(source),\"scope\":\(scope)}"
        guard seen.insert(key).inserted else { continue }
        let packageURL = URL(fileURLWithPath: root).appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: packageURL),
              let package = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = package["version"] as? String else { continue }
        guard let last = settings.getExtensionChangelogVersion(key) else {
            settings.setExtensionChangelogVersion(key, version: version)
            continue
        }
        let validVersion = last.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: #"^v?\d+\.\d+\.\d+"#, options: .regularExpression) != nil
        guard validVersion else {
            settings.setExtensionChangelogVersion(key, version: version)
            continue
        }
        let entries = getNewEntries(parseChangelog(changelog), lastVersion: last)
        if entries.isEmpty { continue }
        settings.setExtensionChangelogVersion(key, version: version)
        let name = package["name"] as? String ?? metadata.source
        let markdown = entries.map { entry in
            entry.content.replacingOccurrences(of: #"^##\s+"#, with: "## \(name) ", options: .regularExpression)
        }.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        updates.append(ExtensionChangelogUpdate(name: name, version: version, markdown: markdown))
    }
    return updates
}
