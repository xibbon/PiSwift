import PiSwiftChord
import PiSwiftDurable
import Synchronization

internal final class EnvWatchLog: Sendable {
    private let state = Mutex<[WatchChange]>([])
    var changes: [WatchChange] { state.withLock { $0 } }
    func append(_ change: WatchChange) { state.withLock { $0.append(change) } }
    static func covers(_ change: WatchChange, _ path: String) -> Bool {
        switch change {
        case .overflow: return true
        case .paths(let paths): return paths.contains { path == $0 || path.hasPrefix($0 + "/") || path.hasPrefix($0 + "\\") }
        case .error: return false
        }
    }
    func wait(for path: String, from: Int) async throws {
        let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while true {
            let updates = Array(changes.dropFirst(from))
            if updates.contains(where: { Self.covers($0, path) }) { return }
            if clock.now > deadline { throw EnvConformanceFailure("No change reported \(path); got \(updates)") }
            try await clock.sleep(for: .milliseconds(20))
        }
    }
}

internal struct EnvWatchChecks: Sendable {
    let env: any ExecutionEnv
    let log: EnvWatchLog
    var changes: [WatchChange] { log.changes }
    func absolute(_ path: String) async throws -> String {
        try await env.absolutePath(path, context: EnvChecks.context).get()
    }
    func expectChange(_ path: String, _ change: () async throws -> Void) async throws {
        let target = try await absolute(path), from = log.changes.count
        try await change()
        try await log.wait(for: target, from: from)
    }
}

extension EnvChecks {
    func watching(_ targets: [WatchTarget], _ body: (EnvWatchChecks) async throws -> Void) async throws {
        let log = EnvWatchLog()
        let watcher = try await env.watch(targets, onChange: { log.append($0) }, context: Self.context).get()
        do {
            try await body(EnvWatchChecks(env: env, log: log))
            await watcher.close(context: Self.context)
        } catch { await watcher.close(context: Self.context); throw error }
    }

    static func case9(_ h: Self) async throws {
        try await h.watching([.init(path: "AGENTS.md")]) { watch in
            try await watch.expectChange("AGENTS.md") { try await h.write("AGENTS.md", "one") }
            try await watch.expectChange("AGENTS.md") { try await h.write("AGENTS.md", "two!") }
            try await watch.expectChange("AGENTS.md") {
                try await h.write("AGENTS.md.tmp", "three"); try await h.rename("AGENTS.md.tmp", "AGENTS.md")
            }
            try await watch.expectChange("AGENTS.md") { try await h.write("AGENTS.md", "four") }
            try await watch.expectChange("AGENTS.md") { try await h.remove("AGENTS.md") }
        }
    }

    static func case10(_ h: Self) async throws {
        try await h.watching([.init(path: "a/b/c/AGENTS.md")]) { watch in
            try await watch.expectChange("a/b/c/AGENTS.md") { try await h.write("a/b/c/AGENTS.md", "x") }
        }
    }

    static func case11(_ h: Self) async throws {
        try await h.directory("skills")
        try await h.watching([.init(path: "skills", recursive: true)]) { watch in
            try await watch.expectChange("skills/a/b/SKILL.md") { try await h.write("skills/a/b/SKILL.md", "one") }
            try await watch.expectChange("skills/a/b/SKILL.md") { try await h.write("skills/a/b/SKILL.md", "two!") }
            try await watch.expectChange("skills/a/b/c/SKILL.md") { try await h.write("skills/a/b/c/SKILL.md", "deeper") }
        }
    }

    static func case12(_ h: Self) async throws {
        try await h.write("proj/.pi/skills/x.md", "x")
        try await h.watching([.init(path: "proj/.pi/skills", recursive: true)]) { watch in
            try await watch.expectChange("proj/.pi/skills") { try await h.rename("proj/.pi", "proj/old") }
            try await watch.expectChange("proj/.pi/skills/y.md") { try await h.write("proj/.pi/skills/y.md", "y") }
            try await watch.expectChange("proj/.pi/skills/y.md") { try await h.write("proj/.pi/skills/y.md", "yy") }
        }
    }

    static func case13(_ h: Self) async throws {
        try await h.directory("skills")
        let targets = [WatchTarget(path: "skills", recursive: true, exclude: .init(hidden: true, names: ["node_modules"]))]
        try await h.watching(targets) { watch in
            try await h.write("skills/node_modules/dep/SKILL.md", "dep")
            try await h.write("skills/.SKILL.md.tmp", "draft")
            try await watch.expectChange("skills/SKILL.md") { try await h.rename("skills/.SKILL.md.tmp", "skills/SKILL.md") }
            let hidden = try await [watch.absolute("skills/node_modules"), watch.absolute("skills/.SKILL.md.tmp")]
            for change in watch.changes {
                if case .paths(let paths) = change {
                    for path in paths {
                        try EnvAssertions.ok(!hidden.contains { path == $0 || path.hasPrefix($0) }, "Excluded \(path)")
                    }
                }
            }
        }
    }

    static func case14(_ h: Self) async throws {
        try await h.write("skills/a/one.md", "one")
        try await h.watching([.init(path: "skills"), .init(path: "skills", recursive: true)]) { watch in
            try await watch.expectChange("skills/a/two.md") { try await h.write("skills/a/two.md", "two") }
        }
    }

    static func case15(_ h: Self) async throws {
        try await h.write("skills/a/x.md", "x")
        try await h.watching([.init(path: "skills", recursive: true)]) { watch in
            try await watch.expectChange("skills/a") {
                try await h.rename("skills/a", "skills-old"); try await h.directory("skills/a")
            }
            try await watch.expectChange("skills/a/y.md") { try await h.write("skills/a/y.md", "y") }
            try await watch.expectChange("skills/a/y.md") { try await h.write("skills/a/y.md", "yy") }
        }
    }

    static func case16(_ h: Self) async throws {
        let log = EnvWatchLog()
        let watcher = try await h.env.watch([.init(path: "file.txt")], onChange: { log.append($0) }, context: context).get()
        try EnvAssertions.ok(watcher.mode == .native || watcher.mode == .polling, "Watcher reports its mode")
        await watcher.close(context: context); await watcher.close(context: context)
        // A second live watch establishes that the change was observed without a fixed sleep.
        try await h.watching([.init(path: "file.txt")]) { watch in
            try await watch.expectChange("file.txt") { try await h.write("file.txt", "x") }
            try EnvAssertions.ok(log.changes.isEmpty, "Closed watcher reported a change")
        }
    }

    static func case24(_ h: Self) async throws {
        try await h.write("data/real.md", "one"); try await h.directory("config")
        try await h.link("../data/real.md", "config/AGENTS.md")
        try await h.watching([.init(path: "config/AGENTS.md")]) { watch in
            try await watch.expectChange("config/AGENTS.md") { try await h.write("data/real.md", "two!") }
        }
    }
}
