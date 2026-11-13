import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

private func gignEnvironment(_ root: URL) -> [String: String] {
    ["HOME": root.appendingPathComponent("home").path,
     "XDG_CONFIG_HOME": root.appendingPathComponent("xdg").path,
     "GIT_CONFIG_GLOBAL": root.appendingPathComponent("home/.gitconfig").path,
     "GIT_CONFIG_SYSTEM": root.appendingPathComponent("no-system-config").path]
}

private func gignWithTree(gitRepository: Bool = true, _ body: (URL) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pi-gign-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    if gitRepository {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: false)
    }
    try await body(root)
}

private func gignWrite(_ relativePath: String, _ content: String = "needle\n", in root: URL) throws {
    let file = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try content.write(to: file, atomically: true, encoding: .utf8)
}

private func gignText(_ result: AgentToolResult) -> String {
    result.content.compactMap {
        if case .text(let text) = $0 { return text.text }
        return nil
    }.joined(separator: "\n")
}

private func gignFind(_ root: URL, path: String? = nil) async throws -> Set<String> {
    var parameters = ["pattern": AnyCodable("**/*.txt")]
    if let path { parameters["path"] = AnyCodable(path) }
    let result = try await createFindTool(cwd: root.path, environment: gignEnvironment(root)).execute("gign-find", parameters, nil, nil)
    let output = gignText(result)
    if output == "No files found matching pattern" { return [] }
    return Set(output.split(separator: "\n").map(String.init))
}

private func gignGrep(_ root: URL, path: String? = nil) async throws -> Set<String> {
    var parameters = ["pattern": AnyCodable("needle")]
    if let path { parameters["path"] = AnyCodable(path) }
    let result = try await createGrepTool(cwd: root.path, options: .init(environment: gignEnvironment(root))).execute("gign-grep", parameters, nil, nil)
    let output = gignText(result)
    if output == "No matches found" { return [] }
    return Set(output.split(separator: "\n").compactMap { line in
        line.range(of: ":1: ").map { String(line[..<$0.lowerBound]) }
    })
}

struct GIGNIgnoreTests {
    @Test("find applies root basename rules at every depth", .timeLimit(.minutes(1)))
    func findRootBasenameRule() async throws {
        try await gignWithTree { root in
            try gignWrite(".gitignore", "*.log\n", in: root)
            try gignWrite("root.log", in: root)
            try gignWrite("sub/deep.log", in: root)
            try gignWrite("root.txt", in: root)
            try gignWrite("sub/keep.txt", in: root)
            // Search all files so the .log rule, rather than the requested glob, decides.
            let result = try await createFindTool(cwd: root.path, environment: gignEnvironment(root)).execute("gign-find", ["pattern": AnyCodable("*")], nil, nil)
            let output = gignText(result)
            #expect(output.contains("root.txt"))
            #expect(output.contains("sub/keep.txt"))
            #expect(!output.contains("root.log"))
            #expect(!output.contains("sub/deep.log"))
        }
    }

    @Test("grep applies root basename rules at every depth", .timeLimit(.minutes(1)))
    func grepRootBasenameRule() async throws {
        try await gignWithTree { root in
            try gignWrite(".gitignore", "*.txt\n", in: root)
            try gignWrite("root.txt", in: root)
            try gignWrite("sub/drop.txt", in: root)
            try gignWrite("root.swift", in: root)
            try gignWrite("sub/keep.swift", in: root)
            #expect(try await gignGrep(root) == ["root.swift", "sub/keep.swift"])
        }
    }

    @Test("find uses a later negation in the same ignore file", .timeLimit(.minutes(1)))
    func findRootNegation() async throws {
        try await gignWithTree { root in
            try gignWrite(".gitignore", "*.txt\n!keep.txt\n", in: root)
            try gignWrite("drop.txt", in: root)
            try gignWrite("keep.txt", in: root)
            try gignWrite("sub/drop.txt", in: root)
            try gignWrite("sub/keep.txt", in: root)
            #expect(try await gignFind(root) == ["keep.txt", "sub/keep.txt"])
        }
    }

    @Test("grep uses a later negation in the same ignore file", .timeLimit(.minutes(1)))
    func grepRootNegation() async throws {
        try await gignWithTree { root in
            try gignWrite(".gitignore", "*.txt\n!keep.txt\n", in: root)
            try gignWrite("drop.txt", in: root)
            try gignWrite("keep.txt", in: root)
            try gignWrite("sub/drop.txt", in: root)
            try gignWrite("sub/keep.txt", in: root)
            #expect(try await gignGrep(root) == ["keep.txt", "sub/keep.txt"])
        }
    }

    // Port of upstream regression 3303-find-nested-gitignore.test.ts, flat sibling case.
    @Test("find scopes a nested ignore file to its own directory (#3303)", .timeLimit(.minutes(1)))
    func findNestedIgnoreDoesNotLeakIntoSibling() async throws {
        try await gignWithTree { root in
            try gignWrite("a/.gitignore", "ignored.txt\n", in: root)
            for path in ["a/ignored.txt", "a/kept.txt", "b/ignored.txt", "b/kept.txt", "root.txt"] {
                try gignWrite(path, in: root)
            }
            #expect(try await gignFind(root) == ["a/kept.txt", "b/ignored.txt", "b/kept.txt", "root.txt"])
        }
    }

    // Port of upstream regression 3303-find-nested-gitignore.test.ts, deep case.
    @Test("find scopes two nested ignore files to their subtrees (#3303)", .timeLimit(.minutes(1)))
    func findDeepNestedIgnoreDoesNotLeak() async throws {
        try await gignWithTree { root in
            try gignWrite("a/.gitignore", "ignored.txt\n", in: root)
            try gignWrite("a/deep/.gitignore", "secret.txt\n", in: root)
            for path in ["a/ignored.txt", "a/kept.txt", "a/deep/ignored.txt", "a/deep/secret.txt",
                         "a/deep/kept.txt", "b/ignored.txt", "b/kept.txt", "root.txt"] {
                try gignWrite(path, in: root)
            }
            #expect(try await gignFind(root) == ["a/deep/kept.txt", "a/kept.txt", "b/ignored.txt", "b/kept.txt", "root.txt"])
        }
    }

    @Test("grep scopes nested ignore files to their subtrees", .timeLimit(.minutes(1)))
    func grepNestedIgnoreDoesNotLeak() async throws {
        try await gignWithTree { root in
            try gignWrite("a/.gitignore", "ignored.txt\n", in: root)
            try gignWrite("a/deep/.gitignore", "secret.txt\n", in: root)
            for path in ["a/ignored.txt", "a/kept.txt", "a/deep/ignored.txt", "a/deep/secret.txt",
                         "a/deep/kept.txt", "b/ignored.txt", "b/kept.txt", "root.txt"] {
                try gignWrite(path, in: root)
            }
            #expect(try await gignGrep(root) == ["a/deep/kept.txt", "a/kept.txt", "b/ignored.txt", "b/kept.txt", "root.txt"])
        }
    }

    @Test("a child ignore file can reinclude a file ignored by its parent", .timeLimit(.minutes(1)))
    func childNegationOverridesParentForBothTools() async throws {
        try await gignWithTree { root in
            try gignWrite(".gitignore", "*.txt\n", in: root)
            try gignWrite("sub/.gitignore", "!keep.txt\n", in: root)
            for path in ["drop.txt", "sub/drop.txt", "sub/keep.txt", "other/keep.txt"] {
                try gignWrite(path, in: root)
            }
            #expect(try await gignFind(root) == ["sub/keep.txt"])
            #expect(try await gignGrep(root) == ["sub/keep.txt"])
        }
    }

    @Test("ignored directories do not yield files even with a child negation", .timeLimit(.minutes(1)))
    func ignoredDirectoryIsPrunedForBothTools() async throws {
        try await gignWithTree { root in
            try gignWrite(".gitignore", "blocked/\n", in: root)
            try gignWrite("blocked/.gitignore", "!keep.txt\n", in: root)
            try gignWrite("blocked/keep.txt", in: root)
            try gignWrite("visible/keep.txt", in: root)
            #expect(try await gignFind(root) == ["visible/keep.txt"])
            #expect(try await gignGrep(root) == ["visible/keep.txt"])
        }
    }

    @Test("outside a Git repository find and grep have different ignore behavior", .timeLimit(.minutes(1)))
    func noRepositoryBehavior() async throws {
        try await gignWithTree(gitRepository: false) { root in
            try gignWrite(".gitignore", "*.txt\n", in: root)
            try gignWrite("drop.txt", in: root)
            try gignWrite("keep.swift", in: root)
            #expect(try await gignFind(root).isEmpty)
            #expect(try await gignGrep(root) == ["drop.txt", "keep.swift"])
        }
    }

    @Test("a parent .gitignore applies below the search root", .timeLimit(.minutes(1)))
    func parentIgnore() async throws {
        try await gignWithTree { root in
            try gignWrite(".gitignore", "drop.txt\n", in: root)
            try gignWrite("sub/drop.txt", in: root)
            try gignWrite("sub/keep.txt", in: root)
            #expect(try await gignFind(root, path: "sub") == ["keep.txt"])
            #expect(try await gignGrep(root, path: "sub") == ["keep.txt"])
        }
    }

    @Test(".ignore applies to both tools outside Git", .timeLimit(.minutes(1)))
    func plainIgnoreOutsideRepository() async throws {
        try await gignWithTree(gitRepository: false) { root in
            try gignWrite(".ignore", "drop.txt\n", in: root)
            try gignWrite("drop.txt", in: root)
            try gignWrite("keep.txt", in: root)
            #expect(try await gignFind(root) == ["keep.txt"])
            #expect(try await gignGrep(root) == ["keep.txt"])
        }
    }

    @Test("tool-specific ignore files apply to their own tool", .timeLimit(.minutes(1)))
    func toolSpecificIgnore() async throws {
        try await gignWithTree { root in
            try gignWrite(".rgignore", "rg.txt\n", in: root)
            try gignWrite(".fdignore", "fd.txt\n", in: root)
            try gignWrite("rg.txt", in: root)
            try gignWrite("fd.txt", in: root)
            try gignWrite("keep.txt", in: root)
            #expect(try await gignFind(root) == ["rg.txt", "keep.txt"])
            #expect(try await gignGrep(root) == ["fd.txt", "keep.txt"])
        }
    }

    @Test("tool-specific rules override .ignore rules", .timeLimit(.minutes(1)))
    func toolSpecificPrecedence() async throws {
        try await gignWithTree { root in
            try gignWrite(".ignore", "drop.txt\n", in: root)
            try gignWrite(".rgignore", "!drop.txt\n", in: root)
            try gignWrite(".fdignore", "!drop.txt\n", in: root)
            try gignWrite("drop.txt", in: root)
            #expect(try await gignFind(root) == ["drop.txt"])
            #expect(try await gignGrep(root) == ["drop.txt"])
        }
    }

    @Test("repository info exclude applies to both tools", .timeLimit(.minutes(1)))
    func infoExclude() async throws {
        try await gignWithTree { root in
            try gignWrite(".git/info/exclude", "drop.txt\n", in: root)
            try gignWrite("drop.txt", in: root)
            try gignWrite("keep.txt", in: root)
            #expect(try await gignFind(root) == ["keep.txt"])
            #expect(try await gignGrep(root) == ["keep.txt"])
        }
    }

    @Test("global git excludes apply to both tools inside a repository", .timeLimit(.minutes(1)))
    func globalGitIgnore() async throws {
        try await gignWithTree { root in
            try gignWrite("home/.gitconfig", "[core]\n  excludesFile = \(root.path)/home/ignore\n", in: root)
            try gignWrite("home/ignore", "drop.txt\n", in: root)
            try gignWrite("drop.txt", in: root)
            try gignWrite("keep.txt", in: root)
            #expect(try await gignFind(root) == ["keep.txt"])
            #expect(try await gignGrep(root) == ["keep.txt"])
        }
    }

    @Test("fd global ignore applies to find only", .timeLimit(.minutes(1)))
    func globalFdIgnore() async throws {
        try await gignWithTree { root in
            try gignWrite("xdg/fd/ignore", "drop.txt\n", in: root)
            try gignWrite("drop.txt", in: root)
            try gignWrite("keep.txt", in: root)
            #expect(try await gignFind(root) == ["keep.txt"])
            #expect(try await gignGrep(root).contains("drop.txt"))
        }
    }

    @Test("fd global negation has tool-specific precedence", .timeLimit(.minutes(1)))
    func globalFdIgnorePrecedence() async throws {
        try await gignWithTree { root in
            try gignWrite(".gitignore", "drop.txt\n", in: root)
            try gignWrite("xdg/fd/ignore", "!drop.txt\n", in: root)
            try gignWrite("drop.txt", in: root)
            #expect(try await gignFind(root) == ["drop.txt"])
            #expect(try await gignGrep(root).isEmpty)
        }
    }

    @Test("an explicit ignored file remains searchable by grep", .timeLimit(.minutes(1)))
    func explicitFile() async throws {
        try await gignWithTree { root in
            try gignWrite(".gitignore", "drop.txt\n", in: root)
            try gignWrite("drop.txt", in: root)
            #expect(try await gignGrep(root).isEmpty)
            let result = try await createGrepTool(cwd: root.path, options: .init(environment: gignEnvironment(root)))
                .execute("explicit", ["pattern": AnyCodable("needle"), "path": AnyCodable("drop.txt")], nil, nil)
            #expect(gignText(result) == "drop.txt:1: needle")
        }
    }

    @Test("a positive grep glob overrides an ignored file", .timeLimit(.minutes(1)))
    func grepGlobOverridesIgnoredFile() async throws {
        try await gignWithTree { root in
            try gignWrite(".gitignore", "drop.txt\n", in: root)
            try gignWrite("drop.txt", in: root)
            let result = try await createGrepTool(cwd: root.path, options: .init(environment: gignEnvironment(root)))
                .execute("override", ["pattern": AnyCodable("needle"), "glob": AnyCodable("drop.txt")], nil, nil)
            #expect(gignText(result) == "drop.txt:1: needle")
        }
    }

    @Test("a positive grep glob does not reopen an ignored directory", .timeLimit(.minutes(1)))
    func grepGlobDoesNotReopenDirectory() async throws {
        try await gignWithTree { root in
            try gignWrite(".gitignore", "blocked/\n", in: root)
            try gignWrite("blocked/drop.txt", in: root)
            let result = try await createGrepTool(cwd: root.path, options: .init(environment: gignEnvironment(root)))
                .execute("override", ["pattern": AnyCodable("needle"), "glob": AnyCodable("drop.txt")], nil, nil)
            #expect(gignText(result) == "No matches found")
        }
    }

    @Test("nested Git repository stops parent Git ignore rules", .timeLimit(.minutes(1)))
    func nestedRepositoryBoundary() async throws {
        try await gignWithTree { root in
            try gignWrite(".gitignore", "drop.txt\n", in: root)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("nested/.git"), withIntermediateDirectories: true)
            try gignWrite("nested/drop.txt", in: root)
            try gignWrite("nested/keep.txt", in: root)
            #expect(try await gignFind(root, path: "nested") == ["drop.txt", "keep.txt"])
            #expect(try await gignGrep(root, path: "nested") == ["drop.txt", "keep.txt"])
        }
    }

    @Test("escaped leading markers, classes, and trailing spaces are parsed", .timeLimit(.minutes(1)))
    func patternSyntax() async throws {
        try await gignWithTree { root in
            try gignWrite(".gitignore", "[ab].txt\n\\#hash.txt\n\\!bang.txt\nspace  \n", in: root)
            for file in ["a.txt", "b.txt", "c.txt", "#hash.txt", "!bang.txt", "space", "keep.txt"] {
                try gignWrite(file, in: root)
            }
            #expect(try await gignFind(root) == ["c.txt", "keep.txt"])
            #expect(try await gignGrep(root) == ["c.txt", "keep.txt"])
        }
    }

    @Test("a symlink does not reopen an ignored directory", .timeLimit(.minutes(1)))
    func symlinkToIgnoredDirectory() async throws {
        try await gignWithTree { root in
            try gignWrite(".gitignore", "blocked/\n", in: root)
            try gignWrite("blocked/drop.txt", in: root)
            try gignWrite("keep.txt", in: root)
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias"),
                                                       withDestinationURL: root.appendingPathComponent("blocked"))
            #expect(try await gignFind(root) == ["keep.txt"])
            #expect(try await gignGrep(root) == ["keep.txt"])
        }
    }

    @Test("three hundred sibling rule files keep their directory scope", .timeLimit(.minutes(2)))
    func manyRuleDirectories() async throws {
        try await gignWithTree { root in
            for index in 0..<300 {
                let directory = String(format: "d%03d", index)
                try gignWrite(directory + "/.ignore", "drop.txt\n", in: root)
            }
            let directory = "d299/"
            try gignWrite(directory + "drop.txt", in: root)
            try gignWrite(directory + "keep.txt", in: root)
            #expect(try await gignFind(root) == [directory + "keep.txt"])
            #expect(try await gignGrep(root) == [directory + "keep.txt"])
        }
    }

    @Test("find's native file set omits matching directory entries", .timeLimit(.minutes(1)))
    func findFileSetOmitsDirectories() async throws {
        try await gignWithTree { root in
            try FileManager.default.createDirectory(at: root.appendingPathComponent("folder.txt"), withIntermediateDirectories: false)
            #expect(try await gignFind(root).isEmpty)
        }
    }

    @Test("hidden Git metadata files remain searchable", .timeLimit(.minutes(1)))
    func hiddenGitMetadataFile() async throws {
        try await gignWithTree { root in
            try gignWrite(".git/config.txt", in: root)
            #expect(try await gignFind(root) == [".git/config.txt"])
            #expect(try await gignGrep(root) == [".git/config.txt"])
        }
    }

    // v1.5.2 packages/coding-agent/test/tools.test.ts:1167-1185.
    @Test("find includes a hidden unignored file", .timeLimit(.minutes(1)))
    func findIncludesHiddenUnignoredFile() async throws {
        try await gignWithTree(gitRepository: false) { root in
            try gignWrite(".secret/hidden.txt", in: root)
            try gignWrite("visible.txt", in: root)
            #expect(try await gignFind(root) == [".secret/hidden.txt", "visible.txt"])
        }
    }
}
