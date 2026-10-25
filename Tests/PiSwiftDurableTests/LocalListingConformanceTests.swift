import Foundation
import Testing
import PiSwiftChord
import PiSwiftDurable
import PiSwiftDurableTesting

private func nativeListingCases() -> [EnvConformanceCase] {
    envConformanceCases(capabilities: .init(exec: false, symlinks: true, watch: false,
                                           listFiles: true, listFilesGitignore: true),
        makeSymlink: { target, path, _ in
            try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)
        }, withEnv: { use in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("pi-native-list-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try await use(LocalExecutionEnv(cwd: root.path))
        }).filter { $0.name.hasPrefix("listFiles ") }
}

struct LocalListingConformanceTests {
    @Test("native listing runs all E8 groups with gitignore", arguments: nativeListingCases())
    func conformance(_ testCase: EnvConformanceCase) async throws { try await testCase.run() }
}
