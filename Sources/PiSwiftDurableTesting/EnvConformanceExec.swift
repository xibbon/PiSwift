import PiSwiftChord
import PiSwiftDurable
import Synchronization

internal final class EnvShellLog: Sendable {
    struct State: Sendable {
        var stdout = ""
        var stderr = ""
        var bytes = 0
        var newlines = 0
        var tail = ""
    }
    let state = Mutex(State())
    func append(_ text: String, _ info: ShellOutputInfo) {
        state.withLock {
            switch info.stream {
            case .stdout: $0.stdout += text
            case .stderr: $0.stderr += text
            }
        }
    }
}

extension EnvChecks {
    func execCollect(_ command: ShellCommand, cwd: String? = nil) async -> (Result<ShellExecResult, ExecutionError>, String, String) {
        let log = EnvShellLog()
        let result = await env.exec(command, options: .init(cwd: cwd, onOutput: { text, _, info in
            log.append(text, info)
        }), context: Self.context)
        return log.state.withLock { (result, $0.stdout, $0.stderr) }
    }

    static func case17(_ h: Self) async throws {
        let hostile = "it's $(touch pwned) `touch pwned` *; touch pwned"
        let (result, stdout, _) = await h.execCollect(.argv(h.shell + ["printf \"%s|%s\" \"$1\" \"$2\"", "argv0", hostile, "a b"]))
        try EnvAssertions.equal(try result.get().exitCode, 0)
        try EnvAssertions.equal(stdout, "\(hostile)|a b")
        try EnvAssertions.equal(try await h.env.exists("pwned", context: context).get(), false)
    }

    static func case18(_ h: Self) async throws {
        let script = "printf out; printf err >&2; printf more"
        for command in [ShellCommand.argv(h.shell + [script]), .shell(script)] {
            let (result, stdout, stderr) = await h.execCollect(command)
            try EnvAssertions.equal(try result.get().exitCode, 0)
            try EnvAssertions.equal(stdout, "outmore")
            try EnvAssertions.equal(stderr, "err")
        }
    }

    static func case19(_ h: Self) async throws {
        try await h.directory("sub")
        let (result, _, _) = await h.execCollect(.argv(h.shell + ["printf x > made.txt; exit 3"]), cwd: "sub")
        try EnvAssertions.equal(try result.get().exitCode, 3)
        try EnvAssertions.equal(try await h.env.readTextFile("sub/made.txt", context: context).get(), "x")
    }

    static func case20(_ h: Self) async throws {
        try EnvAssertions.equal(code(await h.env.exec(.argv(["pi-durable-conformance-missing-program"]), options: nil, context: context)), .spawnError)
        try EnvAssertions.equal(code(await h.env.exec(.argv([]), options: nil, context: context)), .spawnError)
    }

    static func case21(_ h: Self) async throws {
        let lines = 2000
        let window = ShellOutputWindow(maxBytes: 200, maxLines: 5, minIntervalMs: 0, bytesPerSecond: 1_000_000_000)
        let log = EnvShellLog()
        let result = await h.env.exec(.argv(h.shell + ["i=0; while [ $i -lt \(lines) ]; do echo line-$i; i=$((i+1)); done"]),
            options: .init(onOutput: { text, _, info in
                try log.state.withLock { state in
                    if let skipped = info.skipped {
                        state.bytes += skipped.bytes; state.newlines += skipped.newlines
                        let afterNewlines = text.utf8.filter { $0 == 10 }.count
                        try EnvAssertions.ok(text.utf8.count > window.maxBytes || afterNewlines > window.maxLines,
                                             "A skip is followed by more than the window")
                        state.tail = ""
                    }
                    state.bytes += text.utf8.count
                    state.newlines += text.utf8.filter { $0 == 10 }.count
                    state.tail += text
                }
            }, window: window), context: context)
        try EnvAssertions.equal(try result.get().exitCode, 0)
        let expected = (0..<lines).map { "line-\($0)\n" }
        let counts = log.state.withLock { ($0.bytes, $0.newlines, $0.tail) }
        try EnvAssertions.equal(counts.0, expected.joined().utf8.count)
        try EnvAssertions.equal(counts.1, lines)
        try EnvAssertions.ok(counts.2.hasSuffix(expected.suffix(window.maxLines).joined()), "Output does not end with the exact tail")
    }

    static func case22(_ h: Self) async throws {
        // Upstream uses a timeout of 0.1 seconds.
        let timedOut = await h.env.exec(.argv(h.shell + ["sleep 2"]), options: .init(timeout: .milliseconds(100)), context: context)
        try EnvAssertions.equal(code(timedOut), .timeout)
        let controller = AbortController()
        // A reported startup chunk triggers cancellation instead of a fixed sleep.
        let running = await h.env.exec(.argv(h.shell + ["printf started; sleep 2"]), options: .init(onOutput: { _, _, _ in
            controller.abort()
        }), context: context.withAbortSignal(controller.signal))
        try EnvAssertions.equal(code(running), .aborted)
    }
}
