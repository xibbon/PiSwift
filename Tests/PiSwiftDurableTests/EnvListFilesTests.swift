import Testing
import PiSwiftChord
import PiSwiftDurable
import PiSwiftDurableTesting

struct EnvListFilesTests {
    @Test("existing environments report unsupported", arguments: [false, true])
    func unsupported(_ local: Bool) async {
        let env: any ExecutionEnv = local ? LocalExecutionEnv(cwd: "/") : FakeExecutionEnv()
        let controller = AbortController(); controller.abort()
        for context in [ChordContext.background, .background.withAbortSignal(controller.signal)] {
            let result = await env.listFiles("missing", options: .init(maxEntries: -1), context: context)
            if case .failure(let error) = result {
                #expect(error.code == .notSupported)
                #expect(error.path == "missing")
                #expect(error.message == "This environment does not list files")
            } else { Issue.record("An environment without listing support must return not_supported") }
        }
        await env.cleanup(context: .background)
    }

    @Test("listing options preserve omitted fields and apply bound defaults")
    func defaults() throws {
        let options = ListFilesOptions()
        #expect(options.hidden == nil); #expect(options.gitignore == nil); #expect(options.exclude == nil)
        #expect(options.maxEntries == nil); #expect(options.maxBytes == nil); #expect(options.timeoutMs == nil)
        let bounds = try listFilesBounds().get()
        #expect(bounds.maxEntries == 50_000); #expect(bounds.maxBytes == 4 * 1024 * 1024); #expect(bounds.timeoutMs == 10_000)
        #expect(try listFilesBounds(options: options).get() == bounds)
    }

    @Test("rejects every invalid numeric bound", arguments: [
        -1.0, 1.5, Double.infinity, -Double.infinity, Double.nan, 9_007_199_254_740_992,
    ])
    func invalidBounds(_ value: Double) {
        let options = [ListFilesOptions(maxEntries: value), .init(maxBytes: value), .init(timeoutMs: value)]
        for (key, option) in zip(["maxEntries", "maxBytes", "timeoutMs"], options) {
            if case .failure(let error) = listFilesBounds(options: option, path: "root") {
                #expect(error.code == .invalid); #expect(error.path == "root")
                #expect(error.message == "\(key) must be a non-negative safe integer")
            } else { Issue.record("Accepted invalid \(key)") }
        }
    }

    @Test("accepts zero and safe integers and clamps the byte cap")
    func validBounds() throws {
        let zero = try listFilesBounds(options: .init(maxEntries: -0.0, maxBytes: 0, timeoutMs: 0)).get()
        #expect(zero.maxEntries == 0); #expect(zero.maxBytes == 0); #expect(zero.timeoutMs == 0)
        let cap = 16 * 1024 * 1024 - 64 * 1024
        for bytes in [Double(cap), Double(cap + 1), 9_007_199_254_740_991] {
            let bounds = try listFilesBounds(options: .init(maxEntries: 9_007_199_254_740_991,
                                                           maxBytes: bytes, timeoutMs: 9_007_199_254_740_991)).get()
            #expect(bounds.maxEntries == 9_007_199_254_740_991); #expect(bounds.maxBytes == cap)
            #expect(bounds.timeoutMs == 9_007_199_254_740_991)
        }
        if case .failure(let error) = listFilesBounds(options: .init(maxEntries: -1, maxBytes: -1, timeoutMs: -1)) {
            #expect(error.message == "maxEntries must be a non-negative safe integer")
        } else { Issue.record("Accepted negative bounds") }
    }

    @Test("listing checks are opt-in and the symlink check has its own gate")
    func capabilityGates() {
        let provider: @Sendable (@Sendable (any ExecutionEnv) async throws -> Void) async throws -> Void = { _ in }
        let defaults = EnvConformanceCapabilities()
        #expect(!defaults.listFiles); #expect(defaults.listFilesGitignore)
        #expect(!envConformanceCases(withEnv: provider).contains { $0.name.hasPrefix("listFiles ") })
        let all = envConformanceCases(capabilities: .init(listFiles: true), withEnv: provider)
        #expect(all.filter { $0.name.hasPrefix("listFiles ") }.count == 5)
        let withoutLinks = envConformanceCases(capabilities: .init(symlinks: false, listFiles: true), withEnv: provider)
        #expect(withoutLinks.filter { $0.name.hasPrefix("listFiles ") }.count == 4)
    }

    @Test("in-memory listing runs all five conformance groups", arguments: 0..<5)
    func conformance(_ index: Int) async throws {
        let env = ListingTestEnv()
        let cases = envConformanceCases(
            capabilities: .init(exec: false, symlinks: true, watch: false, listFiles: true, listFilesGitignore: false),
            makeSymlink: { target, path, _ in env.addLink(target, at: path) },
            withEnv: { use in try await use(env) }
        ).filter { $0.name.hasPrefix("listFiles ") }
        #expect(cases.count == 5)
        try await cases[index].run()
    }

    @Test("listing counts UTF-8 path bytes and orders sibling names by bytes")
    func utf8AndOrdering() async throws {
        let env = ListingTestEnv()
        let names = ["é", "e", "🙂", "z", "Z"]
        for name in names { try await env.writeFile(name, content: .text(""), context: .background).get() }
        let all = try await env.listFiles(".", options: nil, context: .background).get()
        #expect(all.entries.map { Array($0.path.utf8) } == names.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }.map { Array($0.utf8) })
        let unicode = ListingTestEnv()
        try await unicode.writeFile("é", content: .text(""), context: .background).get()
        let tooSmall = try await unicode.listFiles(".", options: .init(maxBytes: 3), context: .background).get()
        #expect(tooSmall == FileListing(entries: [], truncated: true))
        let exact = try await unicode.listFiles(".", options: .init(maxBytes: 4), context: .background).get()
        #expect(exact == FileListing(entries: [.init(path: "é", kind: .file)], truncated: false))
    }

    @Test("zero time stops a nonempty listing and empty trees do not truncate")
    func zeroLimits() async throws {
        let env = ListingTestEnv()
        let options = ListFilesOptions(maxEntries: 0, maxBytes: 0, timeoutMs: 0)
        #expect(try await env.listFiles(".", options: options, context: .background).get() == FileListing(entries: [], truncated: false))
        try await env.writeFile("a", content: .text(""), context: .background).get()
        #expect(try await env.listFiles(".", options: .init(timeoutMs: 0), context: .background).get() == FileListing(entries: [], truncated: true))
        let controller = AbortController(); controller.abort()
        let invalid = await env.listFiles(".", options: .init(maxBytes: -1), context: .background.withAbortSignal(controller.signal))
        if case .failure(let error) = invalid { #expect(error.code == .invalid) }
        else { Issue.record("Bounds validation must precede cancellation") }
    }
}
