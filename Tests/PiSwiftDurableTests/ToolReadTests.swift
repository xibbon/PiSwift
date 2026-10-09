import Foundation
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

@Suite struct ToolReadTests {
    private let context = ChordContext.background
    private func run(_ text: String, path: String = "f.txt", offset: Double? = nil,
                     limit: Double? = nil) async throws -> ToolExecutionResult {
        let env = FakeExecutionEnv(files: [path: text])
        return try await createReadTool().execute(.object([
            "path": .string(path),
            "offset": offset.map(JSONValue.number) ?? .number(1),
            "limit": limit.map(JSONValue.number) ?? .number(1e20)
        ]), toolTestApi(env: env), context)
    }
    @Test("fails when no environment is configured")
    func missingEnvironment() async throws {
        do {
            _ = try await createReadTool().execute(["path": "x"], toolTestApi(), context)
            Issue.record("Expected a missing environment error")
        } catch { #expect(String(describing: error).contains("No execution environment")) }
    }
    @Test("detects each complete GIF signature", arguments: ["GIF87a", "GIF89a"])
    func gif(_ signature: String) { #expect(detectSupportedImageMimeType(Array(signature.utf8)) == "image/gif") }
    @Test("reads offsets and limits and reports the next offset")
    func offsetsAndLimits() async throws {
        let text = (1...100).map { "Line \($0)" }.joined(separator: "\n")
        let result = try await run(text, offset: 41, limit: 20)
        #expect(toolResultText(result) == (41...60).map { "Line \($0)" }.joined(separator: "\n"))
        #expect(result.diagnostics == [.init(severity: .info, message: "40 more lines in file. Use offset=61 to continue.")])
    }
    @Test("truncates large text at the line limit")
    func lineLimit() async throws {
        let result = try await run((1...2500).map { "Line \($0)" }.joined(separator: "\n"))
        #expect(result.diagnostics == [.init(severity: .info, message: "Showing lines 1-2000 of 2500. Use offset=2001 to continue.", code: "truncated")])
        #expect(result.details?["truncation"]?["totalLines"] == 2500)
        #expect(result.details?["truncation"]?["outputLines"] == 2000)
        #expect(result.details?["truncation"]?["truncatedBy"] == "lines")
    }
    @Test("does not count the trailing newline at the line limit")
    func trailingNewline() async throws {
        let result = try await run(String(repeating: "x\n", count: 2000))
        #expect(toolResultText(result) == String(repeating: "x\n", count: 2000))
        #expect(result.details == nil); #expect(result.diagnostics == [])
    }
    @Test("shows the start of a large line at a character boundary")
    func largeLine() async throws {
        let result = try await run(String(repeating: "é", count: 40_000) + "\nnext\n", path: "long.txt")
        #expect(toolResultText(result) == String(repeating: "é", count: 25_600))
        #expect(result.diagnostics == [.init(severity: .warn, message: "Line 1 is 78.1KB, exceeds the 50.0KB limit; showing its first 50.0KB. Use bash: sed -n '1p' long.txt | tail -c +51201", code: "truncated")])
        #expect(result.details?["truncation"]?["outputBytes"] == 51_200)
        #expect(result.details?["truncation"]?["outputLines"] == 1)
        #expect(result.details?["truncation"]?["firstLineExceedsLimit"] == true)
        #expect(result.details?["truncation"]?["content"] == nil)
    }
    @Test("rejects an offset beyond the last line")
    func beyondEnd() async throws {
        do { _ = try await run("one\ntwo\nthree", path: "short.txt", offset: 100); Issue.record("Expected offset error") }
        catch { #expect(String(describing: error) == "Offset 100 is beyond end of file (3 lines total)") }
    }
    @Test("reads the selected lines from a growing log")
    func growingLog() async throws {
        let reader = ReadTestReader(bytes: Array("one\ntwo\n".utf8), mutation: .grow)
        let result = try await executeReadReader(reader, args: .init(path: "app.log", limit: 2), context: context)
        #expect(toolResultText(result) == "one\ntwo")
        #expect(await reader.closed)
        #expect(await reader.scans == 1)
    }
    @Test("reports a PNG image by its content")
    func image() async throws {
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAX+XDSwAAAABJRU5ErkJggg=="))
        let env = FakeExecutionEnv()
        try await env.writeFile("image.txt", content: .bytes(Array(png)), context: context).get()
        let result = try await createReadTool().execute(["path": "image.txt"], toolTestApi(env: env), context)
        #expect(result.content?.isEmpty == true); #expect(result.isError == true)
        #expect(result.diagnostics == [.init(severity: .error, message: "image.txt is an image (image/png); reading images is not supported", code: "unsupported_image")])
    }
    @Test("reads a rewritten file again once and closes the reader")
    func rewrite() async throws {
        let reader = ReadTestReader(bytes: Array("old\ntext".utf8), mutation: .rewriteOnce)
        let result = try await executeReadReader(reader, args: .init(path: "f.txt"), context: context)
        #expect(toolResultText(result) == "new\ntext")
        #expect(await reader.scans == 2); #expect(await reader.closed)
    }
    @Test("reads a file again after it becomes smaller")
    func shrink() async throws {
        let reader = ReadTestReader(bytes: Array("old\ntext".utf8), mutation: .shrinkOnce)
        let result = try await executeReadReader(reader, args: .init(path: "f.txt"), context: context)
        #expect(toolResultText(result) == "new")
        #expect(await reader.scans == 2); #expect(await reader.closed)
    }
    @Test("fails after two changes and closes the reader")
    func repeatedRewrite() async throws {
        let reader = ReadTestReader(bytes: Array("old\ntext".utf8), mutation: .rewriteAlways)
        do { _ = try await executeReadReader(reader, args: .init(path: "f.txt"), context: context); Issue.record("Expected changed-file error") }
        catch { #expect(String(describing: error) == "f.txt changed while it was read") }
        #expect(await reader.scans == 2); #expect(await reader.closed)
    }
    @Test("bounds each positional read and retained text for a large file")
    func boundedReads() async throws {
        let reader = ReadTestReader(bytes: Array(String(repeating: "x", count: 5 * 1024 * 1024).utf8))
        let result = try await executeReadReader(reader, args: .init(path: "f.txt"), context: context)
        #expect(toolResultText(result).utf8.count == defaultMaxBytes)
        #expect(await reader.maximumRead <= 64 * 1024)
        #expect(await reader.positionalBytes <= 64 * 1024 + 35)
        #expect(result.details?["truncation"]?["totalBytes"] == .number(5 * 1024 * 1024))
    }
    @Test("requires a PNG IHDR header and stops at the first IDAT")
    func pngHeaders() async throws {
        let signature: [UInt8] = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
        #expect(detectSupportedImageMimeType(signature + [0, 0, 0, 12] + Array("IHDR".utf8)) == nil)
        #expect(detectSupportedImageMimeType(signature + [0, 0, 0, 13] + Array("nope".utf8)) == nil)
        let png = signature + [0, 0, 0, 13] + Array("IHDR".utf8) + [UInt8](repeating: 0, count: 17)
            + [0, 0, 0, 0] + Array("IDAT".utf8) + [UInt8](repeating: 0, count: 4)
            + [0, 0, 0, 0] + Array("acTL".utf8) + [UInt8](repeating: 0, count: 4)
        #expect(detectSupportedImageMimeType(png) == "image/png")
        #expect(try await detectSupportedImageMimeTypeOf(.init(size: Int64(png.count), read: { offset, length in
            Array(png.dropFirst(Int(offset)).prefix(length))
        })) == "image/png")
    }
    @Test("checks image edge signatures and BMP headers")
    func imageHeaders() {
        #expect(detectSupportedImageMimeType(Array("GIF89".utf8)) == nil)
        #expect(detectSupportedImageMimeType([0xff, 0xd8, 0xff]) == "image/jpeg")
        #expect(detectSupportedImageMimeType([0xff, 0xd8, 0xff, 0xf7]) == nil)
        #expect(detectSupportedImageMimeType(Array("RIFFxxxxWEBP".utf8)) == "image/webp")
        #expect(detectSupportedImageMimeType(Array("BM".utf8)) == nil)
        var bmp = [UInt8](repeating: 0, count: 30)
        bmp[0] = 0x42; bmp[1] = 0x4d; bmp[2] = 100; bmp[10] = 54; bmp[14] = 40; bmp[26] = 1; bmp[28] = 24
        #expect(detectSupportedImageMimeType(bmp) == "image/bmp")
        bmp[26] = 2; #expect(detectSupportedImageMimeType(bmp) == nil)
    }
}

private actor ReadTestReader: BinaryReader {
    enum Mutation: Sendable { case none, grow, rewriteOnce, rewriteAlways, shrinkOnce }
    private var bytes: [UInt8]
    private let mutation: Mutation
    private var mtime: Int64 = 0
    private var infoCalls = 0
    private(set) var scans = 0
    private(set) var closed = false
    private(set) var maximumRead = 0
    private(set) var positionalBytes = 0
    init(bytes: [UInt8], mutation: Mutation = .none) { self.bytes = bytes; self.mutation = mutation }
    func info(context: ChordContext) async -> Result<FileInfo, FileError> {
        infoCalls += 1
        if infoCalls % 2 == 0 && (mutation == .rewriteAlways || (mutation == .rewriteOnce && infoCalls == 2)) {
            bytes = Array("new\ntext".utf8); mtime += 1
        }
        if mutation == .shrinkOnce && infoCalls == 2 { bytes = Array("new".utf8); mtime += 1 }
        return .success(.init(name: "f.txt", path: "/f.txt", kind: .file, size: Int64(bytes.count), mtimeMs: mtime))
    }
    func read(offset: Int64, length: Int, context: ChordContext) async -> Result<[UInt8], FileError> {
        maximumRead = max(maximumRead, length)
        if mutation == .grow { bytes += Array("more\n".utf8); mtime += 1 }
        let result = Array(bytes.dropFirst(Int(offset)).prefix(length)); positionalBytes += result.count
        return .success(result)
    }
    func scanLines(options: ScanLinesOptions, context: ChordContext) async -> Result<LineScan, FileError> {
        scans += 1
        do {
            var scanner = try LineScanner(startLine: options.startLine, endLine: options.endLine)
            for start in stride(from: 0, to: bytes.count, by: 64 * 1024) {
                scanner.push(Array(bytes[start..<min(start + 64 * 1024, bytes.count)]))
            }
            return .success(scanner.finish())
        } catch { return .failure(.init(.invalid, message: String(describing: error))) }
    }
    func close(context: ChordContext) async { closed = true }
}
