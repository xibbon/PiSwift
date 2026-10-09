import PiSwiftDurable

extension EnvChecks {
    static func case1(_ h: Self) async throws {
        try await h.write("data.txt", "hello world")
        let reader = try await h.env.openBinaryReader("data.txt", options: nil, context: context).get()
        do {
            let info = try await reader.info(context: context).get()
            try EnvAssertions.equal(info.name, "data.txt")
            try EnvAssertions.equal(info.kind, .file)
            try EnvAssertions.equal(info.size, 11)
            try EnvAssertions.equal(decode(try await reader.read(offset: 0, length: 5, context: context).get()), "hello")
            try EnvAssertions.equal(decode(try await reader.read(offset: 6, length: 100, context: context).get()), "world")
            for (offset, length): (Int64, Int) in [(11, 4), (50, 1), (3, 0)] {
                try EnvAssertions.equal(try await reader.read(offset: offset, length: length, context: context).get().count, 0)
            }
            try EnvAssertions.equal(code(await reader.read(offset: -1, length: 1, context: context)), .invalid)
            // A fractional length cannot be passed to the Swift Int API.
            try EnvAssertions.equal(code(await reader.read(offset: 0, length: -1, context: context)), .invalid)
            let beyondSafeInteger: Int64 = 9_007_199_254_740_992
            try EnvAssertions.equal(code(await reader.read(offset: beyondSafeInteger, length: 1, context: context)), .invalid)
            try EnvAssertions.equal(code(await reader.read(offset: 0, length: Int(beyondSafeInteger), context: context)), .invalid)
            try EnvAssertions.equal(code(await reader.read(offset: 0, length: 1, context: abortedContext())), .aborted)
            await reader.close(context: context); await reader.close(context: context)
            try EnvAssertions.equal(code(await reader.read(offset: 0, length: 1, context: context)), .invalid)
            try EnvAssertions.equal(code(await reader.info(context: context)), .invalid)
        } catch { await reader.close(context: context); throw error }
    }

    static func case2(_ h: Self) async throws {
        let bytes: [UInt8] = [0xef, 0xbb, 0xbf, 0x61, 0x0a, 0xe2, 0x82, 0x0a, 0x0a, 0xef, 0xbb, 0xbf, 0x62, 0x0a, 0xc3, 0xa9]
        try await h.env.writeFile("lines.txt", content: .bytes(bytes), context: context).get()
        let lines = decode(bytes).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        try await h.binary("lines.txt") { reader in
            for (start, end): (Int, Int?) in [(0, nil), (0, 1), (1, 3), (2, 3), (3, nil), (4, 9)] {
                let scan = try await reader.scanLines(options: .init(startLine: start, endLine: end), context: context).get()
                let selected = Array(lines[start..<min(end ?? lines.count, lines.count)])
                func range(_ from: Int64, _ to: Int64) -> String { decode(Array(bytes[Int(from)..<Int(to)]), offset: from) }
                try EnvAssertions.equal(scan.newlines, lines.count - 1)
                try EnvAssertions.equal(range(scan.start, scan.end), selected.joined(separator: "\n"))
                try EnvAssertions.equal(scan.selectedBytes, Int64(selected.joined(separator: "\n").utf8.count))
                try EnvAssertions.equal(range(scan.start, scan.firstLineEnd), lines[start])
                try EnvAssertions.equal(scan.firstLineBytes, Int64(lines[start].utf8.count))
            }
            let beyond = try await reader.scanLines(options: .init(startLine: 9), context: context).get()
            try EnvAssertions.equal(beyond.start, Int64(bytes.count))
            try EnvAssertions.equal(beyond.end, Int64(bytes.count))
            try EnvAssertions.equal(beyond.selectedBytes, 0)
            try EnvAssertions.equal(code(await reader.scanLines(options: .init(startLine: 2, endLine: 2), context: context)), .invalid)
        }
    }

    static func case3(_ h: Self) async throws {
        try await h.write("a.txt", "one")
        try await h.binary("a.txt") { reader in
            try await h.rename("a.txt", "b.txt"); try await h.write("a.txt", "two")
            try EnvAssertions.equal(decode(try await reader.read(offset: 0, length: 10, context: context).get()), "one")
        }
    }

    static func case4(_ h: Self) async throws {
        try await h.directory("dir"); try await h.write("file.txt", "x")
        try EnvAssertions.equal(code(await h.env.openBinaryReader("dir", options: nil, context: context)), .isDirectory)
        try EnvAssertions.equal(code(await h.env.openBinaryReader("missing.txt", options: nil, context: context)), .notFound)
        try EnvAssertions.equal(code(await h.env.openBinaryReader("file.txt", options: nil, context: abortedContext())), .aborted)
    }

    static func case5(_ h: Self) async throws {
        let names = ["a.txt", "b.txt", "c.txt", "d.txt", "e.txt"]
        for name in names { try await h.write(name, name) }
        try await h.directory("sub")
        let reader = try await h.env.openDirReader(".", context: context).get()
        do {
            var entries: [FileInfo] = [], done = false
            for _ in 0..<1000 {
                let page = try await reader.next(maxEntries: 2, context: context).get()
                try EnvAssertions.ok(page.entries.count <= 2, "Page exceeds maxEntries")
                entries += page.entries
                if page.done { done = true; break }
            }
            try EnvAssertions.ok(done, "Directory reader did not reach the end")
            try EnvAssertions.equal(entries.map(\.name).sorted(), (names + ["sub"]).sorted())
            try EnvAssertions.equal(entries.first { $0.name == "sub" }?.kind, .directory)
            try EnvAssertions.equal(entries.first { $0.name == "a.txt" }?.kind, .file)
            try EnvAssertions.equal(entries.first { $0.name == "a.txt" }?.size, 5)
            await reader.close(context: context)
        } catch { await reader.close(context: context); throw error }
    }

    static func case6(_ h: Self) async throws {
        try await h.directory("empty")
        let reader = try await h.env.openDirReader("empty", context: context).get()
        do {
            for _ in 0..<2 {
                let page = try await reader.next(maxEntries: 10, context: context).get()
                try EnvAssertions.ok(page.entries.isEmpty && page.done)
            }
            try EnvAssertions.equal(code(await reader.next(maxEntries: 0, context: context)), .invalid)
            try EnvAssertions.equal(code(await reader.next(maxEntries: 1, context: abortedContext())), .aborted)
            await reader.close(context: context); await reader.close(context: context)
            try EnvAssertions.equal(code(await reader.next(maxEntries: 1, context: context)), .invalid)
        } catch { await reader.close(context: context); throw error }
    }

    static func case7(_ h: Self) async throws {
        try await h.write("file.txt", "x")
        try EnvAssertions.equal(code(await h.env.openDirReader("missing", context: context)), .notFound)
        try EnvAssertions.equal(code(await h.env.openDirReader("file.txt", context: context)), .notDirectory)
        try EnvAssertions.equal(code(await h.env.openDirReader(".", context: abortedContext())), .aborted)
    }

    static func case8(_ h: Self) async throws {
        try await h.directory("dir")
        for name in ["x", "y", "z"] { try await h.write("dir/\(name)", name) }
        let reader = try await h.env.openDirReader("dir", context: context).get()
        do {
            for name in ["x", "y", "z"] { try await h.remove("dir/\(name)") }
            var entries: [FileInfo] = []
            for _ in 0..<10 {
                let page = try await reader.next(maxEntries: 10, context: context).get()
                entries += page.entries
                if page.done { break }
            }
            try EnvAssertions.ok(entries.isEmpty)
            await reader.close(context: context)
        } catch { await reader.close(context: context); throw error }
    }

    static func case23(_ h: Self) async throws {
        try await h.write("target.txt", "target"); try await h.directory("sub")
        try await h.write("sub/inner.txt", "inner")
        try await h.link("target.txt", "link.txt"); try await h.link("sub", "dirlink")
        try await h.binary("link.txt") { reader in
            try EnvAssertions.equal(decode(try await reader.read(offset: 0, length: 10, context: context).get()), "target")
        }
        try EnvAssertions.equal(code(await h.env.openBinaryReader("link.txt", options: .init(noFollow: true), context: context)), .invalid)
        try await h.binary("dirlink/inner.txt", options: .init(noFollow: true)) { reader in
            try EnvAssertions.equal(decode(try await reader.read(offset: 0, length: 10, context: context).get()), "inner")
        }
    }
}
