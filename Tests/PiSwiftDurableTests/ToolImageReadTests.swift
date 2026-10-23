import Foundation
import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

// Port of durable/test/tools-images.test.ts at v1.3.0.
@Suite struct ToolImageReadTests {
    private let context = ChordContext.background

    private func read(_ bytes: [UInt8], path: String = "a.png", images: (any ImageProcessor)? = nil,
                      input: [ModelInput] = [.text, .image], resize: ModelImageResizeOptions? = nil,
                      tool: ToolRegistration? = nil) async throws -> ToolExecutionResult {
        let env = FakeExecutionEnv()
        try await env.writeFile(path, content: .bytes(bytes), context: context).get()
        var api = try toolTestApi(env: env)
        api.models = ImageReadModels(input: input, resize: resize)
        api.agent = { _ in Agent(model: .init(provider: "image-test", modelId: "image-test")) }
        return try await (tool ?? createReadTool(images: images)).execute(["path": .string(path)], api, context)
    }

    private func expectImage(_ result: ToolExecutionResult, data: String, mimeType: String) throws {
        #expect(result.output?.count == 1)
        let block = try #require(result.output?.first)
        guard case .image(let image) = block else { Issue.record("Expected an image"); return }
        #expect(image.data == data)
        #expect(image.mimeType == mimeType)
    }

    @Test("Returns supported images without a change", arguments: ["png", "gif"])
    func passThrough(_ format: String) async throws {
        let bytes = format == "png" ? imageReadPNG : imageReadGIF()
        let result = try await read(bytes, path: "image.txt")
        try expectImage(result, data: toBase64(bytes), mimeType: "image/\(format)")
        #expect(result.isError != true)
        #expect(result.details == nil)
        #expect(result.diagnostics == [.init(severity: .info, message: "Read image file [image/\(format)].", code: "image")])
    }

    @Test("Rejects an image above the byte limit without a full read")
    func byteLimitBeforeRead() async throws {
        let reader = ImageReadReader(bytes: imageReadPNG, reportedSize: 4_000_000)
        let result = try await executeReadReader(reader, args: .init(path: "big.png"), context: context)
        #expect(result.isError == true)
        #expect(result.output?.isEmpty == true)
        #expect(result.diagnostics?.first?.code == "unsupported_image")
        #expect(result.diagnostics?.first?.severity == .error)
        #expect(result.diagnostics?.first?.message.contains("too large to send") == true)
        #expect(await reader.maximumRead <= 64 * 1024)
        #expect(await reader.wholeReads == [])
        #expect(await reader.closed)
    }

    @Test("Rejects image width and height above the limits", arguments: [true, false])
    func dimensionLimit(_ width: Bool) async throws {
        let bytes = imageReadGIF(width: width ? 2001 : 1, height: width ? 2 : 3000)
        let result = try await read(bytes, path: "large.gif")
        #expect(result.output?.isEmpty == true)
        #expect(result.isError == true)
        let size = width ? "2001x2" : "1x3000"
        #expect(result.diagnostics?.first?.message == "large.gif is an image (image/gif) of \(size), larger than 2000x2000, and no image processor is configured to shrink it")
    }

    @Test("Rejects BMP when no processor is set")
    func bmpNeedsProcessor() async throws {
        let result = try await read(imageReadBMP(width: 4, height: 4), path: "a.bmp")
        #expect(result.isError == true)
        #expect(result.output?.isEmpty == true)
        #expect(result.diagnostics == [.init(severity: .error, message: "a.bmp is an image (image/bmp) that needs converting, and no image processor is configured", code: "unsupported_image")])
    }

    @Test("Reports an image header with no readable dimensions", arguments: [[UInt8]([0xff, 0xd8, 0xff]), Array("GIF89a".utf8), Array("RIFFxxxxWEBP".utf8)])
    func malformedDimensions(_ bytes: [UInt8]) async throws {
        let result = try await read(bytes, path: "broken.img")
        #expect(result.isError == true)
        #expect(result.output?.isEmpty == true)
        #expect(result.diagnostics?.first?.message.hasSuffix("whose size cannot be read") == true)
    }

    @Test("Reports a placeholder for a text model")
    func placeholder() async throws {
        let result = try await read(imageReadPNG, input: [.text])
        try expectImage(result, data: toBase64(imageReadPNG), mimeType: "image/png")
        #expect(result.diagnostics?.first?.message == "Read image file [image/png]. The current model does not support images; it sees a placeholder instead.")
    }

    @Test("Uses each model limit and preserves the other defaults", arguments: [0, 1, 2])
    func modelLimits(_ field: Int) async throws {
        let resize = field == 0 ? ModelImageResizeOptions(maxWidth: 4) : field == 1 ? ModelImageResizeOptions(maxHeight: 3) : ModelImageResizeOptions(maxBytes: 8)
        let processor = ImageReadProcessor(result: .init(data: "prepared", mimeType: "image/png"))
        let result = try await read(imageReadGIF(width: 8, height: 6), images: processor, resize: resize)
        #expect(result.isError != true)
        #expect(await processor.limits == [ImageLimits(maxWidth: field == 0 ? 4 : 2000, maxHeight: field == 1 ? 3 : 2000, maxBytes: field == 2 ? 8 : 4_718_592)])
        let refused = try await read(imageReadGIF(width: 8, height: 6), resize: resize)
        #expect(refused.isError == true)
        #expect(refused.output?.isEmpty == true)
        if field < 2 {
            #expect(refused.diagnostics?.first?.message.contains(field == 0 ? "larger than 4x2000" : "larger than 2000x3") == true)
        } else {
            #expect(refused.diagnostics?.first?.message.contains("too large to send") == true)
        }
    }

    @Test("Uses default limits when no model is resolved")
    func missingModel() async throws {
        let processor = ImageReadProcessor(result: .init(data: "prepared", mimeType: "image/png"))
        let reader = ImageReadReader(bytes: imageReadPNG)
        let result = try await executeReadReader(reader, args: .init(path: "a.png"), context: context,
            api: toolTestApi(), images: processor)
        #expect(await processor.limits == [defaultImageLimits])
        #expect(result.diagnostics?.first?.message == "Read image file [image/png].")
    }

    @Test("Lists BMP only when a processor is set")
    func description() throws {
        #expect(try createReadTool().declaration.description.contains("(jpg, png, gif, webp)"))
        #expect(try createReadTool(images: ImageReadProcessor(result: nil)).declaration.description.contains("(jpg, png, gif, webp, bmp)"))
    }

    @Test("Reads a growing image again and returns all bytes")
    func growthRetry() async throws {
        let reader = ImageReadReader(bytes: imageReadPNG, changes: 1)
        let result = try await executeReadReader(reader, args: .init(path: "growing.png"), context: context)
        #expect(await reader.wholeReads == [imageReadPNG.count, imageReadPNG.count + 16])
        try expectImage(result, data: toBase64(imageReadPNG + [UInt8](repeating: 0, count: 16)), mimeType: "image/png")
        #expect(await reader.closed)
    }

    @Test("Fails after two image changes and closes the reader")
    func repeatedChanges() async throws {
        let reader = ImageReadReader(bytes: imageReadPNG, changes: 2)
        do {
            _ = try await executeReadReader(reader, args: .init(path: "busy.png"), context: context)
            Issue.record("Expected a changed-file error")
        } catch { #expect(String(describing: error) == "busy.png changed while it was read") }
        #expect(await reader.wholeReads.count == 2)
        #expect(await reader.closed)
    }

    @Test("Runs the processor again when the image grows")
    func processorGrowthRetry() async throws {
        let reader = ImageReadReader(bytes: imageReadPNG, changes: 1)
        let processor = ImageReadProcessor(result: .init(data: "prepared", mimeType: "image/png"))
        _ = try await executeReadReader(reader, args: .init(path: "growing.png"), context: context, images: processor)
        #expect(await processor.bytes == [imageReadPNG, imageReadPNG + [UInt8](repeating: 0, count: 16)])
        #expect(await reader.closed)
    }

    @Test("Reports processor conversion and coordinate scale")
    func processorNotes() async throws {
        let processor = ImageReadProcessor(result: .init(data: "prepared", mimeType: "image/jpeg",
            resized: .init(from: .init(width: 8, height: 6), to: .init(width: 4, height: 3)), convertedFrom: "image/png"))
        let result = try await read(imageReadPNG, images: processor, input: [.text])
        try expectImage(result, data: "prepared", mimeType: "image/jpeg")
        #expect(await processor.bytes == [imageReadPNG])
        #expect(await processor.mimeTypes == ["image/png"])
        #expect(result.diagnostics?.first?.message == "Read image file [image/jpeg]. Converted from image/png to image/jpeg. Resized from 8x6 to 4x3. Multiply coordinates by 2.00 to map them to the original. The current model does not support images; it sees a placeholder instead.")
    }

    @Test("Reports a processor decode failure")
    func processorFailure() async throws {
        let result = try await read(imageReadPNG, images: ImageReadProcessor(result: nil))
        #expect(result.output?.isEmpty == true)
        #expect(result.isError == true)
        #expect(result.diagnostics == [.init(severity: .error, message: "a.png is an image (image/png) that cannot be prepared for the model", code: "unsupported_image")])
    }

    @Test("Passes the processor from the coding tool factory to read")
    func codingFactory() async throws {
        let processor = ImageReadProcessor(result: .init(data: "converted", mimeType: "image/png", convertedFrom: "image/bmp"))
        let tool = try #require(createCodingTools(images: processor).tools.first { $0.declaration.name == "read" })
        let result = try await read(imageReadBMP(width: 4, height: 4), path: "b.bmp", tool: tool)
        try expectImage(result, data: "converted", mimeType: "image/png")
        #expect(await processor.mimeTypes == ["image/bmp"])
    }

    @Test("Cancels processor work and closes the reader", arguments: [true, false])
    func cancellation(_ abort: Bool) async throws {
        let processor = ImageReadWaitingProcessor()
        let reader = ImageReadReader(bytes: imageReadPNG)
        let controller = AbortController()
        let task = Task {
            try await executeReadReader(reader, args: .init(path: "a.png"),
                context: context.withAbortSignal(controller.signal), images: processor)
        }
        await processor.waitUntilStarted()
        if abort { controller.abort() } else { task.cancel() }
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError || String(describing: error) == "Operation aborted") }
        #expect(await processor.cancelled)
        #expect(await reader.closed)
    }

    #if canImport(ImageIO) && canImport(CoreGraphics)
    @Test("Native read preserves image bytes", arguments: ["png", "gif"])
    func nativePassThrough(_ format: String) async throws {
        let bytes = format == "png" ? try await nativePNG(width: 8, height: 6) : imageReadGIF()
        let result = try await read(bytes, images: NativeImageProcessor())
        try expectImage(result, data: toBase64(bytes), mimeType: "image/\(format)")
    }

    @Test("Native read scales an image and reports the coordinate factor")
    func nativeScale() async throws {
        let bytes = try await nativePNG(width: 4000, height: 1000)
        let result = try await read(bytes, path: "wide.png", images: NativeImageProcessor())
        let image = try #require(result.output?.first)
        guard case .image(let block) = image else { Issue.record("Expected an image"); return }
        let data = try #require(Data(base64Encoded: block.data))
        #expect(imageDimensions(Array(data), mimeType: block.mimeType) == .init(width: 2000, height: 500))
        #expect(result.diagnostics?.first?.message == "Read image file [\(block.mimeType)]. Resized from 4000x1000 to 2000x500. Multiply coordinates by 2.00 to map them to the original.")
    }

    @Test("Native read converts a PNG above the byte limit to JPEG")
    func nativeByteLimit() async throws {
        let prepared = try #require(await NativeImageProcessor().prepare(
            bytes: imageReadBMP(width: 1100, height: 1100, noisy: true), mimeType: "image/bmp",
            limits: .init(maxBytes: 20_000_000)))
        #expect(prepared.mimeType == "image/png")
        #expect(prepared.data.utf8.count > defaultImageLimits.maxBytes)
        let bytes = Array(try #require(Data(base64Encoded: prepared.data)))
        let result = try await read(bytes, images: NativeImageProcessor())
        let block = try #require(result.output?.first)
        guard case .image(let image) = block else { Issue.record("Expected an image"); return }
        #expect(image.mimeType == "image/jpeg")
        #expect(image.data.utf8.count <= defaultImageLimits.maxBytes)
        let decoded = Array(try #require(Data(base64Encoded: image.data)))
        #expect(imageDimensions(decoded, mimeType: image.mimeType) == .init(width: 1100, height: 1100))
        #expect(result.diagnostics?.first?.message == "Read image file [image/jpeg]. Converted from image/png to image/jpeg.")
    }

    @Test("Native read converts BMP to PNG")
    func nativeBMP() async throws {
        let result = try await read(imageReadBMP(width: 4, height: 4), path: "a.bmp", images: NativeImageProcessor())
        let image = try #require(result.output?.first)
        guard case .image(let block) = image else { Issue.record("Expected an image"); return }
        #expect(block.mimeType == "image/png")
        #expect(result.diagnostics?.first?.message == "Read image file [image/png]. Converted from image/bmp to image/png.")
    }

    @Test("Native read reports a corrupt image")
    func nativeCorrupt() async throws {
        let result = try await read(Array(imageReadPNG.prefix(40)), path: "broken.png", images: NativeImageProcessor())
        #expect(result.output?.isEmpty == true)
        #expect(result.isError == true)
        #expect(result.diagnostics?.first?.message == "broken.png is an image (image/png) that cannot be prepared for the model")
    }

    private func nativePNG(width: Int, height: Int) async throws -> [UInt8] {
        let result = try #require(await NativeImageProcessor().prepare(bytes: imageReadBMP(width: width, height: height),
            mimeType: "image/bmp", limits: .init(maxWidth: 5000, maxHeight: 5000)))
        return Array(try #require(Data(base64Encoded: result.data)))
    }
    #endif
}

private let imageReadPNG = Array(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAX+XDSwAAAABJRU5ErkJggg==")!)

private func imageReadGIF(width: Int = 1, height: Int = 1) -> [UInt8] {
    var bytes = Array(Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")!)
    bytes[6] = UInt8(width & 255); bytes[7] = UInt8(width >> 8)
    bytes[8] = UInt8(height & 255); bytes[9] = UInt8(height >> 8)
    return bytes
}

private func imageReadBMP(width: Int, height: Int, noisy: Bool = false) -> [UInt8] {
    let row = ((width * 3 + 3) / 4) * 4
    var bytes = [UInt8](repeating: 0, count: 54 + row * height)
    func set(_ value: Int, at offset: Int, count: Int = 4) {
        for index in 0..<count { bytes[offset + index] = UInt8((value >> (index * 8)) & 255) }
    }
    bytes[0] = 0x42; bytes[1] = 0x4d
    set(bytes.count, at: 2); set(54, at: 10); set(40, at: 14)
    set(width, at: 18); set(height, at: 22); set(1, at: 26, count: 2); set(24, at: 28, count: 2)
    set(row * height, at: 34)
    var seed: UInt32 = 1
    for y in 0..<height {
        for x in 0..<width {
            let offset = 54 + y * row + x * 3
            if noisy {
                for channel in 0..<3 {
                    seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
                    bytes[offset + channel] = UInt8(truncatingIfNeeded: seed)
                }
            } else { bytes[offset + 2] = 255 }
        }
    }
    return bytes
}

private struct ImageReadModels: DurableModels {
    let model: Model
    init(input: [ModelInput], resize: ModelImageResizeOptions?) {
        model = Model(id: "image-test", name: "image-test", api: .openAICompletions, provider: "image-test",
            baseUrl: "", reasoning: false, input: input, cost: .init(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
            contextWindow: 100, maxTokens: 10, inputLimits: resize.map { .init(images: .init(resize: $0)) })
    }
    func getModel(provider: String, modelId: String) -> Model? { model }
    func streamSimple(model: Model, context: PiSwiftAI.Context, options: SimpleStreamOptions) -> AssistantMessageEventStream {
        FakeDurableModels().streamSimple(model: model, context: context, options: options)
    }
}

private actor ImageReadProcessor: ImageProcessor {
    let result: PreparedImage?
    private(set) var limits: [ImageLimits] = []
    private(set) var bytes: [[UInt8]] = []
    private(set) var mimeTypes: [String] = []
    init(result: PreparedImage?) { self.result = result }
    func prepare(bytes: [UInt8], mimeType: String, limits: ImageLimits) async throws -> PreparedImage? {
        self.bytes.append(bytes); self.mimeTypes.append(mimeType); self.limits.append(limits)
        return result
    }
}

private actor ImageReadWaitingProcessor: ImageProcessor {
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var cancelled = false
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func prepare(bytes: [UInt8], mimeType: String, limits: ImageLimits) async throws -> PreparedImage? {
        started = true
        for waiter in waiters { waiter.resume() }; waiters = []
        do { try await Task.sleep(for: .seconds(30)); return nil }
        catch { cancelled = Task.isCancelled; throw error }
    }
}

private actor ImageReadReader: BinaryReader {
    private var bytes: [UInt8]
    private let reportedSize: Int64?
    private let changes: Int
    private var changeCount = 0
    private(set) var maximumRead = 0
    private(set) var wholeReads: [Int] = []
    private(set) var closed = false
    init(bytes: [UInt8], reportedSize: Int64? = nil, changes: Int = 0) {
        self.bytes = bytes; self.reportedSize = reportedSize; self.changes = changes
    }
    func info(context: ChordContext) async -> Result<FileInfo, FileError> {
        .success(.init(name: "image", path: "/image", kind: .file, size: reportedSize ?? Int64(bytes.count), mtimeMs: Int64(changeCount)))
    }
    func read(offset: Int64, length: Int, context: ChordContext) async -> Result<[UInt8], FileError> {
        maximumRead = max(maximumRead, length)
        let result = Array(bytes.dropFirst(Int(offset)).prefix(length))
        if offset == 0 && length >= bytes.count {
            wholeReads.append(length)
            if changeCount < changes { bytes += [UInt8](repeating: 0, count: 16); changeCount += 1 }
        }
        return .success(result)
    }
    func scanLines(options: ScanLinesOptions, context: ChordContext) async -> Result<LineScan, FileError> {
        .failure(.init(.invalid, message: "An image must not use the text scanner"))
    }
    func close(context: ChordContext) async { closed = true }
}
