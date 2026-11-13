import Foundation
import Testing
import PiSwiftAI
@testable import PiSwiftCodingAgent

struct GIGNBenchmarkTests {
    // The old traversal mirrors FindTool.swift at 5430e0d. It gives a stable
    // before/after walk comparison without changing the process environment.
    @Test("20,000-file no-ignore walk timing", .timeLimit(.minutes(3)))
    func noIgnoreFilesTiming() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pi-gign-benchmark-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for directory in 0..<100 {
            let folder = root.appendingPathComponent(String(format: "%03d", directory))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            for file in 0..<200 {
                try Data().write(to: folder.appendingPathComponent(String(format: "%03d.txt", file)))
            }
        }
        let clock = ContinuousClock()
        let beforeStart = clock.now
        var oldCount = 0
        let basePath = root.resolvingSymlinksInPath().path
        let basePrefix = basePath.hasSuffix("/") ? basePath : basePath + "/"
        let oldPattern = try NSRegularExpression(pattern: "^.*\\.txt$", options: [.caseInsensitive])
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsPackageDescendants]) {
            while let url = enumerator.nextObject() as? URL {
                let relative = url.resolvingSymlinksInPath().path.replacingOccurrences(of: basePrefix, with: "")
                let normalized = relative.replacingOccurrences(of: "\\", with: "/")
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let candidate = url.lastPathComponent
                if !isDirectory && !normalized.isEmpty &&
                    oldPattern.firstMatch(in: candidate, range: NSRange(candidate.startIndex..., in: candidate)) != nil {
                    oldCount += 1
                }
            }
        }
        let before = beforeStart.duration(to: clock.now)
        let afterStart = clock.now
        let environment = ["HOME": root.appendingPathComponent("home").path,
                           "XDG_CONFIG_HOME": root.appendingPathComponent("xdg").path,
                           "GIT_CONFIG_GLOBAL": root.appendingPathComponent("no-config").path,
                           "GIT_CONFIG_SYSTEM": root.appendingPathComponent("no-system-config").path]
        let result = try await createFindTool(cwd: root.path, environment: environment).execute("benchmark", [
            "pattern": AnyCodable("*.txt"), "limit": AnyCodable(20_001),
        ], nil, nil)
        let after = afterStart.duration(to: clock.now)
        let truncation = result.details?.value as? [String: Any]
        let totalLines = (truncation?["truncation"] as? [String: Any])?["totalLines"] as? Int
        #expect(oldCount == 20_000)
        #expect(totalLines == 20_000)
        print("G-IGN 20000-file old-walk \(before), new-find \(after), isolated HOME \(environment["HOME"] != nil)")
    }
}
