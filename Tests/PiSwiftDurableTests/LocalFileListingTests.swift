import Foundation
import Synchronization
import Testing
import PiSwiftChord
@testable import PiSwiftDurable
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

internal struct ListingTree {
    let root: String
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pi-list-L1-\(UUID())").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(atPath: root) }
    func write(_ path: String, _ text: String = "") throws {
        let absolute = root + "/" + path
        try FileManager.default.createDirectory(atPath: (absolute as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: absolute))
    }
    var environment: [String: String] {
        ["HOME": root + "/home", "XDG_CONFIG_HOME": root + "/xdg", "GIT_CONFIG_SYSTEM": root + "/missing-system"]
    }
    func list(_ path: String = "", options: ListFilesOptions? = nil,
              environment: [String: String]? = nil, hooks: LocalListingHooks = .init(),
              context: ChordContext = .background) async throws -> FileListing {
        try await LocalFileListing.list(root + (path.isEmpty ? "" : "/" + path), options: options,
                                        context: context, environment: environment ?? self.environment, hooks: hooks).get()
    }
}

struct LocalFileListingTests {
    @Test("native listing validates negative maxEntries before normal or aborted I/O", arguments: [false, true])
    func nativeNegativeEntries(_ aborted: Bool) async {
        let controller = AbortController()
        if aborted { controller.abort() }
        let result = await LocalExecutionEnv(cwd: "/").listFiles("missing", options: .init(maxEntries: -1),
            context: .background.withAbortSignal(controller.signal))
        if case .failure(let error) = result {
            #expect(error.code == .invalid)
            #expect(error.path == "/missing")
            #expect(error.message == "maxEntries must be a non-negative safe integer")
        } else { Issue.record("Native listing accepted a negative entry bound") }
    }

    @Test("global config scans raw bytes and decodes only the captured setting")
    func rawConfig() throws {
        let tree = try ListingTree(); defer { tree.remove() }
        var environment = tree.environment
        environment["GIT_CONFIG_GLOBAL"] = tree.root + "/config"
        let prefix: [UInt8] = [35, 255, 10]
        let path = tree.root + "/é-ignore"
        try Data(prefix + Array(("[core]\nexcludesFile = " + path + "\n").utf8)).write(to: URL(fileURLWithPath: tree.root + "/config"))
        #expect(GitIgnoreSources.globalPath(environment: environment, processDirectory: tree.root) == path)
        try Data(Array("excludesFile = ".utf8) + [255, 10] + Array(("excludesFile = " + path + "\n").utf8))
            .write(to: URL(fileURLWithPath: tree.root + "/config"))
        // The crate uses the first capture; invalid UTF-8 makes this source supply no path.
        #expect(GitIgnoreSources.globalPath(environment: environment, processDirectory: tree.root) == tree.root + "/xdg/git/ignore")
        try Data([35, 0x85] + Array(("excludesFile = " + path + "\n").utf8))
            .write(to: URL(fileURLWithPath: tree.root + "/config"))
        #expect(GitIgnoreSources.globalPath(environment: environment, processDirectory: tree.root) == tree.root + "/xdg/git/ignore")
    }
    @Test("sources use deeper rules, info rules, and global rules in that order")
    func precedence() async throws {
        let tree = try ListingTree(); defer { tree.remove() }
        try tree.write(".git/HEAD")
        try tree.write(".git/info/exclude", "*.info\n!info-keep.global\n")
        try tree.write(".gitignore", "*.root\n!root-keep.info\nblocked/\n!blocked/keep\nparent/*\n!parent/keep/\n")
        try tree.write("sub/.gitignore", "!keep.root\n*.deep\n")
        try tree.write("xdg/git/ignore", "*.global\n*.info\n")
        for path in ["drop.global", "drop.info", "drop.root", "root-keep.info", "info-keep.global",
                     "sub/keep.root", "sub/drop.root", "sub/drop.deep", "blocked/keep", "parent/drop/x", "parent/keep/x"] {
            try tree.write(path)
        }
        let listing = try await tree.list()
        let paths = listing.entries.map(\.path)
        for path in ["root-keep.info", "info-keep.global", "sub/keep.root", "parent/keep/x"] { #expect(paths.contains(path)) }
        for path in ["drop.global", "drop.info", "drop.root", "sub/drop.root", "sub/drop.deep", "blocked", "blocked/keep", "parent/drop"] {
            #expect(!paths.contains(path))
        }
        #expect(try await tree.list("sub").entries.map(\.path) == [".gitignore", "keep.root"])
    }

    @Test("outside repositories, .ignore, nested repositories, .jj, and hidden whitelist")
    func repositoryRules() async throws {
        let tree = try ListingTree(); defer { tree.remove() }
        try tree.write(".gitignore", "*.log\n!.shown\n")
        try tree.write(".ignore", "keep\n")
        try tree.write("drop.log"); try tree.write("keep"); try tree.write(".shown"); try tree.write(".hidden")
        #expect(try await tree.list().entries.contains { $0.path == "drop.log" })
        try tree.write(".git/HEAD")
        try tree.write("nested/.git/HEAD"); try tree.write("nested/keep.log")
        let paths = try await tree.list(options: .init(hidden: false)).entries.map(\.path)
        #expect(paths == [".shown", "keep", "nested", "nested/keep.log"])
        #expect(try await tree.list(options: .init(gitignore: false)).entries.contains { $0.path == "drop.log" })
        try FileManager.default.removeItem(atPath: tree.root + "/.git")
        try tree.write(".jj/repo")
        #expect(try await !tree.list().entries.contains { $0.path == "drop.log" })
    }

    @Test("config lookup uses the pinned crate's order and parsing")
    func configLookup() throws {
        let tree = try ListingTree(); defer { tree.remove() }
        var environment = tree.environment
        environment["GIT_CONFIG_GLOBAL"] = tree.root + "/global-config"
        func path() -> String? { GitIgnoreSources.globalPath(environment: environment, processDirectory: tree.root) }
        #expect(path() == tree.root + "/xdg/git/ignore")
        try tree.write("system", "[core]\nexcludesFile = relative-ignore\n")
        environment["GIT_CONFIG_SYSTEM"] = tree.root + "/system"
        #expect(path() == tree.root + "/relative-ignore")
        try tree.write("xdg/git/config", "[core]\nexcludesFile = ~/xdg-ignore\n")
        #expect(path() == tree.root + "/home/xdg-ignore")
        try tree.write("home/.gitconfig", "[other]\nEXCLUDESFILE = \"~/home-ignore\"\n")
        #expect(path() == tree.root + "/home/home-ignore")
        try tree.write("global-config", "[core]\nexcludesFile = \"~/global-ignore\"\nexcludesFile = ignored-second\n")
        #expect(path() == tree.root + "/home/global-ignore")
        try tree.write("global-config", "[core]\nexcludesFile = \"has spaces\"\n")
        #expect(path() == tree.root + "/home/home-ignore")
        environment["XDG_CONFIG_HOME"] = ""
        try FileManager.default.removeItem(atPath: tree.root + "/home/.gitconfig")
        environment["GIT_CONFIG_SYSTEM"] = tree.root + "/missing"
        #expect(path() == tree.root + "/home/.config/git/ignore")
    }

    @Test("global patterns use the listing root; linked work trees require commondir")
    func globalAnchorAndGitFile() async throws {
        let tree = try ListingTree(); defer { tree.remove() }
        try tree.write(".git", "gitdir: \(tree.root)/metadata\n")
        try tree.write("metadata/info/exclude", "target\n")
        try tree.write("target"); try tree.write("sub/target")
        #expect(try await tree.list().entries.contains { $0.path == "target" })
        try tree.write("metadata/commondir", ".\n")
        #expect(try await !tree.list().entries.contains { $0.path == "target" })
        try tree.write("xdg/git/ignore", "/anchored\n")
        try tree.write("sub/anchored")
        #expect(try await tree.list().entries.contains { $0.path == "sub/anchored" })
        #expect(try await !tree.list("sub").entries.contains { $0.path == "anchored" })
    }

    @Test("byte limits use lossy UTF-8 paths and byte order without Unicode normalization")
    func byteNames() async throws {
        let tree = try ListingTree(); defer { tree.remove() }
        for name in ["é", "e\u{301}x", "z", "A"] { try tree.write(name) }
        var expected = try FileManager.default.contentsOfDirectory(atPath: tree.root)
        expected.sort { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        let raw = Array((tree.root + "/").utf8) + [255]
        let fd = LocalListingPath.withCString(raw) { open($0, O_WRONLY | O_CREAT, 0o600) }
        if fd >= 0 { close(fd); expected.append("�") }
        else {
            #expect(errno == EILSEQ || errno == EINVAL)
            print("L1 invalid UTF-8 filename case unavailable: file system rejects the name (errno \(errno))")
        }
        let paths = try await tree.list().entries.map(\.path)
        #expect(paths.map { Array($0.utf8) } == expected.map { Array($0.utf8) })
        let bytes = paths.reduce(0) { $0 + $1.utf8.count + 2 }
        #expect(try await !tree.list(options: .init(maxBytes: Double(bytes))).truncated)
        let short = try await tree.list(options: .init(maxBytes: Double(bytes - 1)))
        #expect(short.truncated && short.entries.count == paths.count - 1)
    }

    @Test("zero bounds truncate only at an eligible entry; validation precedes abort")
    func boundsAndAbort() async throws {
        let tree = try ListingTree(); defer { tree.remove() }
        #expect(try await tree.list(options: .init(maxEntries: 0, maxBytes: 0, timeoutMs: 0)) == .init(entries: [], truncated: false))
        try tree.write(".git/HEAD"); try tree.write(".gitignore", "*\n")
        #expect(try await !tree.list(options: .init(maxEntries: 0, maxBytes: 0, timeoutMs: 0)).truncated)
        #expect(try await tree.list(options: .init(gitignore: false, timeoutMs: 0)).truncated)
        let abort = AbortController(); abort.abort()
        let invalid = await LocalFileListing.list(tree.root, options: .init(maxBytes: -1), context: .background.withAbortSignal(abort.signal))
        if case .failure(let error) = invalid { #expect(error.code == .invalid) } else { Issue.record("Invalid bound accepted") }
    }

    @Test("I/O uses a worker, and cancellation and time are checked during the walk")
    @MainActor func workerAndCancellation() async throws {
        let tree = try ListingTree(); defer { tree.remove() }
        try tree.write("dir/file")
        let abort = AbortController(), count = Mutex(0), worker = Mutex(true)
        let hooks = LocalListingHooks(beforeDirectory: {
            worker.withLock { $0 = $0 && !Thread.isMainThread }
            if count.withLock({ $0 += 1; return $0 }) == 2 { abort.abort() }
        })
        let result = await LocalFileListing.list(tree.root, options: nil, context: .background.withAbortSignal(abort.signal),
                                                 environment: tree.environment, hooks: hooks)
        #expect(worker.withLock { $0 })
        if case .failure(let error) = result { #expect(error.code == .aborted) } else { Issue.record("Walk did not abort") }
        let delayed = try await tree.list(options: .init(timeoutMs: 1), hooks: .init(beforeDirectory: { Thread.sleep(forTimeInterval: 0.01) }))
        #expect(delayed.entries.isEmpty && delayed.truncated)
    }

    @Test("deep walk uses a stack and omits unsupported file kinds")
    func deepTree() async throws {
        let tree = try ListingTree(); defer { tree.remove() }
        let path = Array(repeating: "d", count: 250).joined(separator: "/") + "/file"
        try tree.write(path)
        #expect(mkfifo(tree.root + "/pipe", 0o600) == 0)
        let listing = try await tree.list()
        #expect(listing.entries.count == 251 && !listing.truncated)
        #expect(listing.entries.last?.path == path)
    }

    @Test("ignore files stop at invalid UTF-8 and read rules across buffer boundaries")
    func streamedRules() async throws {
        let tree = try ListingTree(); defer { tree.remove() }
        try tree.write(".git/HEAD"); try tree.write("before"); try tree.write("after"); try tree.write("boundary")
        let bytes = Array(("#" + String(repeating: "x", count: 8190) + "\nboundary\r\nbefore\n").utf8) + [255, 10] + Array("after\n".utf8)
        try Data(bytes).write(to: URL(fileURLWithPath: tree.root + "/.gitignore"))
        let paths = try await tree.list().entries.map(\.path)
        #expect(!paths.contains("before") && !paths.contains("boundary") && paths.contains("after"))
    }

    @Test("a linked root uses canonical parent rules and bypasses its own exclusion")
    func linkedRootParents() async throws {
        let tree = try ListingTree(); defer { tree.remove() }
        try tree.write(".git/HEAD"); try tree.write(".gitignore", "target/\n*.log\n")
        try tree.write("target/drop.log"); try tree.write("target/keep")
        try FileManager.default.createSymbolicLink(atPath: tree.root + "/alias", withDestinationPath: "target")
        #expect(try await tree.list("alias").entries.map(\.path) == ["keep"])
        #expect(try await tree.list().entries.map(\.path) == [".gitignore", "alias"])
        try tree.write("target/.gitignore", "!drop.log\n")
        #expect(try await tree.list("alias").entries.map(\.path) == [".gitignore", "drop.log", "keep"])
    }

    @Test("an unreadable child directory is listed and its entries are skipped")
    func unreadableDirectory() async throws {
        let tree = try ListingTree(); defer { tree.remove() }
        try tree.write("locked/file")
        #expect(chmod(tree.root + "/locked", 0) == 0)
        defer { _ = chmod(tree.root + "/locked", 0o700) }
        let listing = try await tree.list()
        #expect(listing.entries.first == .init(path: "locked", kind: .directory))
        if access(tree.root + "/locked", R_OK) != 0 { #expect(listing.entries.count == 1) }
        else { print("L1 unreadable-directory check: this user can read mode-000 directories; child assertion unavailable") }
    }

    @Test("50,000 entries finish within the default listing time limit")
    func largeTree() async throws {
        let tree = try ListingTree(); defer { tree.remove() }
        // Fixture construction also runs outside the cooperative executor.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            DispatchQueue(label: "PiSwiftDurableTests.list.fixture").async {
                do {
                    for index in 0..<50_000 { try tree.write(String(format: "%05d", index)) }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
        let start = ContinuousClock.now
        let listing = try await LocalExecutionEnv(cwd: tree.root).listFiles(".", options: nil, context: .background).get()
        let elapsed = start.duration(to: .now)
        print("L1 50,000 entries: \(elapsed)")
        #expect(listing.entries.count == 50_000 && !listing.truncated)
        #expect(elapsed < .seconds(15))
        #expect(listing.entries.first?.path == "00000" && listing.entries.last?.path == "49999")
    }
}
