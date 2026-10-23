import PiSwiftChord
import PiSwiftDurable
import Synchronization

/// A check that can run with any asynchronous test runner.
public struct EnvConformanceCase: Sendable, CustomStringConvertible {
    /// The upstream case name.
    public let name: String
    /// The suggested runner timeout, in milliseconds.
    public let timeoutMs: Int?
    /// Runs the check.
    public let run: @Sendable () async throws -> Void
    /// Creates a named check.
    public init(name: String, timeoutMs: Int? = nil, run: @escaping @Sendable () async throws -> Void) {
        self.name = name; self.timeoutMs = timeoutMs; self.run = run
    }
    /// The case name for display.
    public var description: String { name }
}

/// Selects the supported environment checks.
public struct EnvConformanceCapabilities: Sendable {
    /// Include the six shell checks.
    public var exec: Bool
    /// Include the two symbolic link checks.
    public var symlinks: Bool
    /// Include file watch checks.
    public var watch: Bool
    /// Include tree listing checks. Disabled by default.
    public var listFiles: Bool
    /// Include gitignore assertions in the listing checks. Requires listFiles; enabled by default.
    /// A test fake can disable this flag and still check `.git` and name exclusions.
    public var listFilesGitignore: Bool
    /// Selects the supported checks. Listing is disabled by default; other checks are enabled.
    public init(exec: Bool = true, symlinks: Bool = true, watch: Bool = true,
                listFiles: Bool = false, listFilesGitignore: Bool = true) {
        self.exec = exec; self.symlinks = symlinks; self.watch = watch
        self.listFiles = listFiles; self.listFilesGitignore = listFilesGitignore
    }
}

/// A failed environment check, with its source location.
public struct EnvConformanceFailure: Error, Sendable, CustomStringConvertible {
    /// The failed check message.
    public let message: String
    /// The source file that contains the failed check.
    public let file: String
    /// The source line that contains the failed check.
    public let line: UInt
    /// Creates a failed check with its message and source location.
    public init(_ message: String, file: String = #filePath, line: UInt = #line) {
        self.message = message; self.file = file; self.line = line
    }
    /// The failure message and source location for display.
    public var description: String { "\(file):\(line): \(message)" }
}

/// Creates the upstream checks. The provider must await its callback once with a fresh, empty, writable cwd.
/// The link hook receives the relative link target and the absolute path at which to create the link.
public func envConformanceCases(
    capabilities: EnvConformanceCapabilities = .init(),
    shell: [String] = ["sh", "-c"],
    makeSymlink: (@Sendable (_ target: String, _ linkPath: String, _ context: ChordContext) async throws -> Void)? = nil,
    withEnv: @escaping @Sendable (@Sendable (any ExecutionEnv) async throws -> Void) async throws -> Void
) -> [EnvConformanceCase] {
    typealias Check = @Sendable (EnvChecks) async throws -> Void
    var checks: [(String, Int?, Check)] = [
        ("binary reader reads byte ranges of the opened file", nil, EnvChecks.case1),
        ("binary reader scans lines like decoding the whole file", nil, EnvChecks.case2),
        ("binary reader keeps reading the file it opened after a rename", nil, EnvChecks.case3),
        ("binary reader refuses directories, missing files and aborted opens", nil, EnvChecks.case4),
        ("directory reader pages every entry exactly once", nil, EnvChecks.case5),
        ("directory reader reports the end and refuses use after close", nil, EnvChecks.case6),
        ("directory reader refuses missing paths and files", nil, EnvChecks.case7),
        ("directory reader skips entries removed during enumeration", nil, EnvChecks.case8),
    ]
    if capabilities.watch {
        checks += [
            ("watch reports a missing file's creation, changes, replacement and removal", 30_000, EnvChecks.case9),
            ("watch reports a missing target whose ancestors are created", 30_000, EnvChecks.case10),
            ("watch follows directories created together with their contents", 30_000, EnvChecks.case11),
            ("watch keeps watching a path whose parent is renamed and recreated", 30_000, EnvChecks.case12),
            ("watch skips excluded entries and reports a rename out of them", 30_000, EnvChecks.case13),
            ("watch keeps recursive coverage where a non-recursive target overlaps", 30_000, EnvChecks.case14),
            ("watch follows a directory replaced at the same path", 30_000, EnvChecks.case15),
            ("watch stops reporting once closed", 30_000, EnvChecks.case16),
        ]
    }
    if capabilities.exec {
        checks += [
            ("argv exec passes arguments to the program without shell parsing", nil, EnvChecks.case17),
            ("exec reports the stream of every chunk in both forms", nil, EnvChecks.case18),
            ("argv exec honors cwd and exit codes", nil, EnvChecks.case19),
            ("argv exec reports missing programs and empty argv as spawn errors", nil, EnvChecks.case20),
            ("windowed exec keeps the exact tail and counts what it skips", nil, EnvChecks.case21),
            ("argv exec distinguishes timeout from abort", nil, EnvChecks.case22),
        ]
    }
    if capabilities.listFiles {
        checks += [
            ("listFiles lists files and directories depth first in name order", nil, { @Sendable in try await $0.case25() }),
            ("listFiles skips what git ignores in work trees, .git, and excluded names", nil, { @Sendable check in
                try await check.case26(gitignore: capabilities.listFilesGitignore)
            }),
            ("listFiles stops at its bounds and reports truncated", nil, { @Sendable in try await $0.case27() }),
            ("listFiles fails on missing directories, files, and aborts", nil, { @Sendable in try await $0.case28() }),
        ]
        if capabilities.symlinks {
            checks.append(("listFiles lists symbolic links without following them", nil, { @Sendable in try await $0.case29() }))
        }
    }
    if capabilities.symlinks {
        checks.append(("binary reader follows symlinks unless noFollow refuses the final one", nil, EnvChecks.case23))
        if capabilities.watch {
            checks.append(("watch reports changes to the file a watched symbolic link points to", 30_000, EnvChecks.case24))
        }
    }
    return checks.map { name, timeout, check in
        EnvConformanceCase(name: name, timeoutMs: timeout) {
            try await withEnv { env in
                try await check(EnvChecks(env: env, shell: shell, makeSymlink: makeSymlink))
            }
        }
    }
}

internal enum EnvAssertions {
    static func ok(_ value: Bool, _ message: String = "Expected true", file: String = #filePath, line: UInt = #line) throws {
        if !value { throw EnvConformanceFailure(message, file: file, line: line) }
    }
    static func equal<T: Equatable>(_ actual: T, _ expected: T, file: String = #filePath, line: UInt = #line) throws {
        try ok(actual == expected, "Expected \(expected); got \(actual)", file: file, line: line)
    }
}

internal struct EnvChecks: Sendable {
    let env: any ExecutionEnv
    let shell: [String]
    let makeSymlink: (@Sendable (String, String, ChordContext) async throws -> Void)?
    static let context = ChordContext.background
    static func abortedContext() -> ChordContext {
        let controller = AbortController(); controller.abort()
        return context.withAbortSignal(controller.signal)
    }
    static func code<T>(_ value: Result<T, FileError>) -> FileErrorCode? {
        if case .failure(let error) = value { return error.code }; return nil
    }
    static func code<T>(_ value: Result<T, ExecutionError>) -> ExecutionErrorCode? {
        if case .failure(let error) = value { return error.code }; return nil
    }
    static func decode(_ bytes: [UInt8], offset: Int64 = 0) -> String {
        let value = offset == 0 && bytes.starts(with: [0xef, 0xbb, 0xbf]) ? Array(bytes.dropFirst(3)) : bytes
        return String(decoding: value, as: UTF8.self)
    }
    func write(_ path: String, _ text: String) async throws {
        try await env.writeFile(path, content: .text(text), context: Self.context).get()
    }
    func directory(_ path: String) async throws {
        try await env.createDir(path, options: nil, context: Self.context).get()
    }
    func remove(_ path: String) async throws {
        try await env.remove(path, options: nil, context: Self.context).get()
    }
    func rename(_ source: String, _ destination: String) async throws {
        try await env.renameFile(source, destinationPath: destination, context: Self.context).get()
    }
    func binary<T: Sendable>(_ path: String, options: OpenBinaryReaderOptions? = nil,
                             _ body: (any BinaryReader) async throws -> T) async throws -> T {
        let reader = try await env.openBinaryReader(path, options: options, context: Self.context).get()
        do { let result = try await body(reader); await reader.close(context: Self.context); return result }
        catch { await reader.close(context: Self.context); throw error }
    }
    func link(_ target: String, _ path: String) async throws {
        guard let makeSymlink else { throw EnvConformanceFailure("The symlink capability requires makeSymlink") }
        let absolute = try await env.absolutePath(path, context: Self.context).get()
        try await makeSymlink(target, absolute, Self.context)
    }
}

// Upstream durable/src/testing/env-conformance.ts:484-588 (v1.3.0).
internal extension EnvChecks {
    func listed(_ path: String = ".", options: ListFilesOptions? = nil) async throws -> FileListing {
        try await env.listFiles(path, options: options, context: Self.context).get()
    }
    func listedPaths(_ path: String = ".", options: ListFilesOptions? = nil) async throws -> [String] {
        try await listed(path, options: options).entries.map { entry in
            let kind = switch entry.kind { case .file: "f"; case .directory: "d"; case .symlink: "l" }
            return "\(kind) \(entry.path)"
        }
    }
    func writeListingFiles(_ paths: [String]) async throws {
        for path in paths {
            let parts = path.split(separator: "/").dropLast().map(String.init)
            if !parts.isEmpty {
                try await env.createDir(parts.joined(separator: "/"), options: .init(recursive: true), context: Self.context).get()
            }
            try await write(path, "")
        }
    }
    func case25() async throws {
        try await writeListingFiles(["b.txt", "a/z.txt", "a/b/c.txt", ".hidden/x", "A.txt"])
        try await directory("empty")
        try EnvAssertions.equal(try await listedPaths(), [
            "d .hidden", "f .hidden/x", "f A.txt", "d a", "d a/b", "f a/b/c.txt", "f a/z.txt", "f b.txt", "d empty",
        ])
        try EnvAssertions.equal(try await listed().truncated, false)
        try EnvAssertions.equal(try await listedPaths(options: .init(hidden: false)), [
            "f A.txt", "d a", "d a/b", "f a/b/c.txt", "f a/z.txt", "f b.txt", "d empty",
        ])
        let expected = ["d b", "f b/c.txt", "f z.txt"]
        try EnvAssertions.equal(try await listedPaths("a"), expected)
        try EnvAssertions.equal(try await listed("a").truncated, false)
        let absolute = try await env.absolutePath("a", context: Self.context).get()
        try EnvAssertions.equal(try await listedPaths(absolute), expected)
        try EnvAssertions.equal(try await listed(absolute).truncated, false)
        try EnvAssertions.equal(try await listed("empty"), FileListing(entries: [], truncated: false))
    }
    func case26(gitignore: Bool) async throws {
        try await writeListingFiles(["keep.txt", "out/x.js", "sub/keep.txt", "sub/drop.log", "node_modules/m/i.js"])
        try await write(".gitignore", "out/\n*.log\n")
        try await write("sub/.gitignore", "!keep.txt\n")
        try EnvAssertions.ok(try await listedPaths().contains("f out/x.js"))
        try await writeListingFiles([".git/HEAD", ".git/info/exclude"])
        try await write(".git/HEAD", "ref: refs/heads/main\n")
        try await write(".git/info/exclude", "keep.txt\n")
        if gitignore {
            try EnvAssertions.equal(try await listedPaths(options: .init(exclude: ["node_modules"])), [
                "f .gitignore", "d sub", "f sub/.gitignore", "f sub/keep.txt",
            ])
            try EnvAssertions.equal(try await listedPaths("sub"), ["f .gitignore", "f keep.txt"])
        }
        try await writeListingFiles(["sub/node_modules/x", "sub/.git/config"])
        let all = try await listedPaths(options: .init(gitignore: false))
        try EnvAssertions.ok(all.contains("f out/x.js") && all.contains("f node_modules/m/i.js") && all.contains("f keep.txt"))
        try EnvAssertions.ok(!all.contains { entry in
            entry == "d .git" || entry.contains(".git/") || entry.hasSuffix("/.git")
        })
        let excluded = try await listedPaths(options: .init(gitignore: false, exclude: ["node_modules"]))
        try EnvAssertions.equal(excluded, [
            "f .gitignore", "f keep.txt", "d out", "f out/x.js", "d sub", "f sub/.gitignore", "f sub/drop.log", "f sub/keep.txt",
        ])
        try await env.remove(".git", options: .init(recursive: true), context: Self.context).get()
        try await write(".git", "gitdir: elsewhere\n")
        try EnvAssertions.ok(!(try await listedPaths(options: .init(gitignore: false))).contains("f .git"))
    }
    func case27() async throws {
        try await writeListingFiles(["a", "b", "c"])
        let firstTwo = [FileListEntry(path: "a", kind: .file), FileListEntry(path: "b", kind: .file)]
        try EnvAssertions.equal(try await listed(options: .init(maxEntries: 2)), FileListing(entries: firstTwo, truncated: true))
        try EnvAssertions.equal(try await listed(options: .init(maxEntries: 3)),
                                FileListing(entries: firstTwo + [.init(path: "c", kind: .file)], truncated: false))
        try EnvAssertions.equal(try await listed(options: .init(maxBytes: 6)), FileListing(entries: firstTwo, truncated: true))
        try EnvAssertions.equal(try await listed(options: .init(maxEntries: 0)), FileListing(entries: [], truncated: true))
        try EnvAssertions.equal(try await listed(options: .init(maxBytes: 0)), FileListing(entries: [], truncated: true))
        try EnvAssertions.equal(Self.code(await env.listFiles(".", options: .init(maxEntries: -1), context: Self.context)), .invalid)
        try EnvAssertions.equal(Self.code(await env.listFiles(".", options: .init(timeoutMs: 1.5), context: Self.context)), .invalid)
    }
    func case28() async throws {
        try await write("file.txt", "")
        try EnvAssertions.equal(Self.code(await env.listFiles("missing", options: nil, context: Self.context)), .notFound)
        try EnvAssertions.equal(Self.code(await env.listFiles("file.txt", options: nil, context: Self.context)), .notDirectory)
        try EnvAssertions.equal(Self.code(await env.listFiles(".", options: nil, context: Self.abortedContext())), .aborted)
    }
    func case29() async throws {
        try await writeListingFiles(["dir/inner.txt"])
        try await link("dir", "link")
        try await link("missing", "dangling")
        try await link("..", "dir/loop")
        try EnvAssertions.equal(try await listedPaths(), ["l dangling", "d dir", "f dir/inner.txt", "l dir/loop", "l link"])
        try EnvAssertions.equal(try await listedPaths("link"), ["f inner.txt", "l loop"])
        try EnvAssertions.equal(try await listed("link").truncated, false)
    }
}
