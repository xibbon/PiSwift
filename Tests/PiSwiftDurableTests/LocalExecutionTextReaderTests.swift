import Foundation
import Synchronization
import Testing
import PiSwiftChord
@testable import PiSwiftDurable

@Suite struct LocalExecutionTextReaderTests {
    private let context = ChordContext.background
    private func withEnv(_ body: (LocalExecutionEnv) async throws -> Void) async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("pi-e1-text-" + UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: path) }
        try await body(LocalExecutionEnv(cwd: path))
    }
    @Test("reads strict LF lines and reports final unterminated records")
    func strictLF() async throws {
        try await withEnv { env in
            try await env.writeFile("lines.txt", content: .text("one\r\n\ntwo\npartial"), context: context).get()
            let reader = try await env.openTextLineReader("lines.txt", context: context).get()
            var lines: [TextLine] = []
            while let line = try await reader.readLine(context: context).get() { lines.append(line) }
            #expect(lines == [.init(text: "one\r", terminated: true), .init(text: "", terminated: true), .init(text: "two", terminated: true), .init(text: "partial", terminated: false)])
            #expect(try await reader.readLine(context: context).get() == nil)
            await reader.close(context: context)
        }
    }
    @Test("returns no lines for an empty file and one terminated empty line for a lone newline")
    func emptyAndNewline() async throws {
        try await withEnv { env in
            try await env.writeFile("empty.txt", content: .text(""), context: context).get()
            try await env.writeFile("newline.txt", content: .text("\n"), context: context).get()
            let empty = try await env.openTextLineReader("empty.txt", context: context).get()
            #expect(try await empty.readLine(context: context).get() == nil)
            await empty.close(context: context)
            let newline = try await env.openTextLineReader("newline.txt", context: context).get()
            #expect(try await newline.readLine(context: context).get() == .init(text: "", terminated: true))
            #expect(try await newline.readLine(context: context).get() == nil)
            await newline.close(context: context)
        }
    }
    @Test("decodes multi-byte characters split across read chunks and lines longer than one chunk")
    func longLines() async throws {
        try await withEnv { env in
            let first = String(repeating: "a", count: 64 * 1024 - 2) + "😀tail"
            let second = String(repeating: "é", count: 100_000)
            try await env.writeFile("large.txt", content: .text(first + "\n" + second), context: context).get()
            let reader = try await env.openTextLineReader("large.txt", context: context).get()
            #expect(try await reader.readLine(context: context).get() == .init(text: first, terminated: true))
            #expect(try await reader.readLine(context: context).get() == .init(text: second, terminated: false))
            #expect(try await reader.readLine(context: context).get() == nil)
            await reader.close(context: context)
        }
    }
    @Test("rejects a read cancelled while pending without consuming its bytes")
    func pendingCancellation() async throws {
        try await withEnv { env in
            try await env.writeFile("lines.txt", content: .text("one\ntwo\n"), context: context).get()
            let started = EnvReadGate(), released = EnvReadGate()
            let first = Mutex(true)
            let hooked = LocalExecutionEnv(cwd: env.cwd, io: .init(beforeRead: {
                if first.withLock({ value in let result = value; value = false; return result }) {
                    await started.signal()
                    await released.wait()
                }
            }))
            let reader = try await hooked.openTextLineReader("lines.txt", context: context).get()
            let child = context.withCancel()
            let pending = Task { await reader.readLine(context: child.context) }
            await started.wait()
            child.cancel()
            await released.signal()
            if case .failure(let error) = await pending.value { #expect(error.code == .aborted) }
            else { Issue.record("Expected cancellation") }
            #expect(try await reader.readLine(context: context).get() == .init(text: "one", terminated: true))
            #expect(try await reader.readLine(context: context).get() == .init(text: "two", terminated: true))
            #expect(try await reader.readLine(context: context).get() == nil)
            await reader.close(context: context)
        }
    }
    @Test("rejects reads after close and closes idempotently")
    func closed() async throws {
        try await withEnv { env in
            try await env.writeFile("lines.txt", content: .text("one\n"), context: context).get()
            let reader = try await env.openTextLineReader("lines.txt", context: context).get()
            await reader.close(context: context); await reader.close(context: context)
            if case .failure(let error) = await reader.readLine(context: context) {
                #expect(error.code == .invalid); #expect(error.path == env.cwd + "/lines.txt")
            } else { Issue.record("Expected closed reader failure") }
        }
    }
    @Test("reports missing files when opening a reader")
    func missing() async throws {
        try await withEnv { env in
            if case .failure(let error) = await env.openTextLineReader("missing.txt", context: context) {
                #expect(error.code == .notFound); #expect(error.path == env.cwd + "/missing.txt")
            } else { Issue.record("Expected missing file failure") }
        }
    }
    @Test("preserves interior BOM bytes at a read boundary")
    func interiorBOM() async throws {
        try await withEnv { env in
            let text = "\u{feff}" + String(repeating: "a", count: 64 * 1024 - 3) + "\u{feff}tail\n"
            try await env.writeFile("bom.txt", content: .text(text), context: context).get()
            #expect(try await env.readTextFile("bom.txt", context: context).get().utf8.elementsEqual(text.utf8))
            let lines = try await env.readTextLines("bom.txt", options: nil, context: context).get()
            #expect(lines[0].utf8.elementsEqual(text.dropFirst().dropLast().utf8))
        }
    }
}

private actor EnvReadGate {
    private var open = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !open { await withCheckedContinuation { waiting.append($0) } } }
    func signal() { open = true; let values = waiting; waiting.removeAll(); for value in values { value.resume() } }
}
