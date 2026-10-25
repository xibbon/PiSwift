#if os(macOS)
import Foundation
import Testing
@testable import PiSwiftDurable

private enum ListingGitOracle {
    static let executable: String? = {
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":") {
            let path = String(directory) + "/git"
            if FileManager.default.isExecutableFile(atPath: path) {
                let process = Process(); process.executableURL = URL(fileURLWithPath: path); process.arguments = ["--version"]
                process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                if (try? process.run()) != nil { process.waitUntilExit(); if process.terminationStatus == 0 { return path } }
            }
        }
        return nil
    }()

    static func run(_ arguments: [String], tree: ListingTree, environment: [String: String], input: [String]? = nil) throws -> [String] {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: try #require(executable))
        process.currentDirectoryURL = URL(fileURLWithPath: tree.root)
        // No user Git settings or process-global environment changes.
        process.environment = environment
        process.arguments = ["-c", "core.ignorecase=false", "-c", "core.precomposeunicode=false"] + arguments
        process.standardOutput = output; process.standardError = output
        let inputPipe = Pipe()
        if input != nil { process.standardInput = inputPipe }
        try process.run()
        if let input {
            try inputPipe.fileHandleForWriting.write(contentsOf: Data((input.joined(separator: "\0") + "\0").utf8))
            try inputPipe.fileHandleForWriting.close()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let allowed = process.terminationStatus == 0 || (arguments.first == "check-ignore" && process.terminationStatus == 1)
        try #require(allowed, "git \(arguments): \(String(decoding: data, as: UTF8.self))")
        return data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }
}

struct LocalListingGitOracleTests {
    @Test("Git wildcard matrix includes escaped spaces, classes, stars, and directory pruning",
          .enabled(if: ListingGitOracle.executable != nil, "Git is missing or cannot run; the differential test needs Git"))
    func wildcardMatrix() async throws {
        let tree = try ListingTree(); defer { tree.remove() }
        var environment = tree.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        _ = try ListingGitOracle.run(["init", "-q"], tree: tree, environment: environment)
        let names = ["a", "b", "c", "Z", "2", "-", "]", "[", "[abc", "[[:", "x.txt", "drop.log", "keep.log",
                     "#hash", "!bang", "space", "space ", "back\\", "back\\ ", "tab", "tab\t", "a*b", "é", "ab", "aab"]
        for prefix in ["", "foo/", "foo/x/", "foo/x/y/", "other/"] {
            for name in names { try tree.write(prefix + name) }
        }
        try tree.write("foo/bar/leaf"); try tree.write("foo/x/bar/leaf")
        try FileManager.default.createSymbolicLink(atPath: tree.root + "/dirlink", withDestinationPath: "foo")
        try FileManager.default.createSymbolicLink(atPath: tree.root + "/dangling", withDestinationPath: "missing")
        // Crate-only cases are in GitIgnoreTests.cratePatterns, not in this Git oracle.
        let patterns = ["# comment", "\\#hash", "\\!bang", "space   ", "space\\ ", "\\a", "a\\*b", "x\\", "*", "?", "??", "*.log", "*.log\n!keep.log",
                        "/a", "foo/a", "foo/", "dirlink/", "dangling/", "foo/*", "foo/**", "**/a", "**/foo/a",
                        "foo/**/a", "foo/**/bar", "a**b", "foo/**a", "foo/*a", "foo/*/a",
                        "foo/*\n!foo/x/", "foo/\n!foo/x/a", "foo/*\n!foo/x/\nfoo/x/*\n!foo/x/a",
                        "[a-c]", "[!ab]", "[^ab]", "[]a]", "[-a]", "[a-]", "[z-a]",
                        "***", "**", "**/", "foo/**/**/a"]
        var mismatches = 0
        for pattern in patterns {
            try tree.write(".gitignore", pattern + "\n")
            let expected = Set(try ListingGitOracle.run(["ls-files", "-z", "--cached", "--others", "--exclude-standard"], tree: tree, environment: environment))
            let actual = Set(try await tree.list(environment: environment).entries.filter { $0.kind != .directory }.map(\.path))
            if actual != expected { mismatches += 1 }
            #expect(actual == expected, "Git wildcard mismatch for \(String(reflecting: pattern)); extra \(actual.subtracting(expected)); missing \(expected.subtracting(actual))")
        }
        print("L1 Git wildcard matrix: \(patterns.count) patterns; \(mismatches) mismatches")
    }

    @Test("generated trees agree with Git after index-independent ignore filtering",
          .enabled(if: ListingGitOracle.executable != nil, "Git is missing or cannot run; the differential test needs Git"))
    func differential() async throws {
        let patterns = ["*.log", "**/cache/", "[ab]?.tmp", "/root-only", "foo/**/bar", "trail\\ ",
                        "\\#hash", "\\!bang", "a/**", "a/*", "**/leaf?.dat", "[0-9]*.num"]
        var totalFiles = 0, totalDirectories = 0
        for seed in 0..<12 {
            let tree = try ListingTree(); defer { tree.remove() }
            var environment = tree.environment
            environment["PATH"] = "/usr/bin:/bin"
            environment["GIT_CONFIG_GLOBAL"] = tree.root + "/home/config"
            environment["GIT_CONFIG_NOSYSTEM"] = "1"
            try tree.write("home/config", "[core]\nexcludesFile = \(tree.root)/home/global-ignore\n")
            try tree.write("home/global-ignore", "*.global\n*.shared\n!global-keep.shared\n")
            _ = try ListingGitOracle.run(["init", "-q"], tree: tree, environment: environment)
            let selected = (0..<4).map { patterns[(seed + $0 * 3) % patterns.count] }.joined(separator: "\n")
            try tree.write(".gitignore", selected + "\nblocked/\n!blocked/keep\n*.tracked\n!root-keep.info\n!local-keep.global\n*.shared\n")
            try tree.write(".git/info/exclude", "*.info\n*.shared\n!info-keep.global\n")
            try tree.write("sub/.gitignore", "!keep.log\n!keep.shared\nchild-only/\n*.child\n")
            try tree.write("sub/deep/.gitignore", "!keep.child\n*.deep\n")
            try tree.write(".ignore", "visible\n")
            var files = [".gitignore", "sub/.gitignore", "sub/deep/.gitignore", ".ignore", "home/config", "home/global-ignore"]
            let names = ["drop.log", "keep.log", "aa.tmp", "bz.tmp", "cz.tmp", "root-only", "trail ", "#hash", "!bang",
                         "leaf1.dat", "leaf22.dat", "0a.num", "drop.global", "local-keep.global", "info-keep.global",
                         "root-keep.info", "drop.info", "keep.shared", "drop.shared", "keep.child", "drop.child", "drop.deep", "visible"]
            let prefixes = ["", "sub/", "sub/deep/", "a/", "a/b/", "foo/", "foo/x/", "foo/x/y/", "cache/", "sub/cache/"]
            for prefix in prefixes {
                for name in names { let path = prefix + name; try tree.write(path); files.append(path) }
            }
            for path in ["blocked/keep", "blocked/drop", "foo/bar/x", "foo/x/bar/x", "sub/child-only/x", "forced.tracked", "tracked-visible"] {
                try tree.write(path); files.append(path)
            }
            // Index entries must not defeat ignore rules in the native walker.
            _ = try ListingGitOracle.run(["add", "--force", "--", "forced.tracked", "tracked-visible"], tree: tree, environment: environment)
            let gitFiles = Set(try ListingGitOracle.run(["ls-files", "-z", "--cached", "--others", "--exclude-standard"], tree: tree, environment: environment))
            #expect(gitFiles.contains("forced.tracked"))
            let ignored = Set(try ListingGitOracle.run(["check-ignore", "--no-index", "-z", "--stdin"], tree: tree, environment: environment, input: Array(gitFiles)))
            let listed = try await tree.list(environment: environment)
            #expect(!listed.truncated)
            let actual = Set(listed.entries.filter { $0.kind != .directory }.map(\.path))
            #expect(actual == gitFiles.subtracting(ignored), "file mismatch in generated case \(seed)")
            #expect(!actual.contains("forced.tracked") && actual.contains("tracked-visible"))
            var directories: Set<String> = []
            for file in files {
                var parts = file.split(separator: "/").dropLast()
                while !parts.isEmpty { directories.insert(parts.joined(separator: "/")); parts = parts.dropLast() }
            }
            let ignoredDirectories = Set(try ListingGitOracle.run(["check-ignore", "--no-index", "-z", "--stdin"], tree: tree, environment: environment, input: Array(directories)))
            #expect(Set(listed.entries.filter { $0.kind == .directory }.map(\.path)) == directories.subtracting(ignoredDirectories),
                    "directory mismatch in generated case \(seed)")
            totalFiles += files.count; totalDirectories += directories.count
        }
        print("L1 Git differential: 12 trees, \(totalFiles) file cases, \(totalDirectories) directory cases; no mismatches")
    }
}
#endif
