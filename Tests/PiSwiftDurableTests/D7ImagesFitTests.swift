import Foundation
import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

#if canImport(ImageIO) && canImport(CoreGraphics)
import CoreGraphics
import ImageIO

// Port of packages/durable/test/images-fit.test.ts at v1.6.0. Fixtures have
// the same dimensions, colours, noise generator and EXIF orientation as the
// upstream fixtures; ImageIO encodes them, so compressed bytes can differ.
@Suite("D7 images fit") struct D7ImagesFitTests {
    private let processor = NativeImageProcessor()

    private func image(_ bytes: [UInt8], _ mime: String) -> ContentBlock {
        .image(.init(data: toBase64(bytes), mimeType: mime))
    }
    private func fitted(_ result: FittedImages) throws -> ([ContentBlock], [String]) {
        guard case .fitted(let content, let notes) = result else { throw FitTestError.notFitted }
        return (content, notes)
    }
    private func imageBlock(_ block: ContentBlock?) throws -> ImageContent {
        guard case .image(let image) = block else { throw FitTestError.noImage }
        return image
    }
    private func dimensions(_ image: ImageContent) throws -> ImageDimensions {
        let data = try #require(Data(base64Encoded: image.data))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return .init(width: decoded.width, height: decoded.height)
    }

    @Test("prepares an image from its bytes, as base64 for the model")
    func preparesAnImageFromItsBytesAsBase64ForTheModel() async throws {
        let png = try fixture(8, 6)
        switch await fitImage(bytes: png, mimeType: "image/png", limits: defaultImageLimits, processor: processor) {
        case .fitted(let result, let notes):
            #expect(result.data == toBase64(png)); #expect(result.mimeType == "image/png"); #expect(notes == [])
        case .omitted: Issue.record("Expected a fitted image")
        }
    }

    @Test("leaves out an image the processor fails on, with the failure in its note")
    func leavesOutAnImageTheProcessorFailsOnWithTheFailureInItsNote() async throws {
        let result = await fitImage(bytes: try fixture(8, 6), mimeType: "image/png",
                                    limits: defaultImageLimits, processor: FailingFitProcessor())
        guard case .omitted(let note) = result else { Issue.record("Expected omission"); return }
        #expect(note == "An image (image/png) cannot be prepared for the model and was left out: worker exited.")
    }

    @Test("is unchanged when every image comes back as it was, and asks the processor only about images")
    func isUnchangedWhenEveryImageComesBackAsItWasAndAsksTheProcessorOnlyAboutImages() async throws {
        let recorder = RecordingFitProcessor(base: processor)
        let content: [ContentBlock] = [.text(.init(text: "a")), image(try fixture(8, 6), "image/png")]
        guard case .unchanged = await fitImages(content: content, limits: defaultImageLimits, processor: recorder) else {
            Issue.record("Expected unchanged content"); return
        }
        #expect(await recorder.calls == ["image/png"])
        guard case .unchanged = await fitImages(content: [.text(.init(text: "only text"))],
                                               limits: defaultImageLimits, processor: recorder) else {
            Issue.record("Expected unchanged text"); return
        }
        #expect(await recorder.calls == ["image/png"])
    }

    @Test("scales an image beyond the limits down, keeps the text in place, and says how to map coordinates back")
    func scalesAnImageBeyondTheLimitsDownKeepsTheTextInPlaceAndSaysHowToMapCoordinatesBack() async throws {
        let text = TextContent(text: "before")
        let (content, notes) = try fitted(await fitImages(content: [.text(text), image(try fixture(400, 100), "image/png"),
            .text(.init(text: "after"))], limits: .init(maxWidth: 200), processor: processor))
        #expect(content.count == 3)
        guard case .text(let before) = content[0], case .text(let after) = content[2] else {
            Issue.record("Text moved"); return
        }
        #expect(before.text == "before"); #expect(after.text == "after")
        #expect(try dimensions(imageBlock(content[1])) == .init(width: 200, height: 50))
        #expect(notes == ["Resized from 400x100 to 200x50. Multiply coordinates by 2.00 to map them to the original."])
    }

    @Test("re-encodes an image within the dimensions but over the byte limit")
    func reEncodesAnImageWithinTheDimensionsButOverTheByteLimit() async throws {
        let png = try fixture(64, 64, noise: true)
        #expect(toBase64(png).utf8.count > 8_000)
        let (content, notes) = try fitted(await fitImages(content: [image(png, "image/png")],
            limits: .init(maxBytes: 8_000), processor: processor))
        let result = try imageBlock(content.first)
        #expect(result.data.utf8.count <= 8_000)
        #expect(!notes.isEmpty)
    }

    @Test("turns an image upright that fits but carries an EXIF orientation")
    func turnsAnImageUprightThatFitsButCarriesAnEXIFOrientation() async throws {
        let jpeg = try fixture(40, 30, jpeg: true)
        let (content, _) = try fitted(await fitImages(content: [image(oriented(jpeg), "image/jpeg")],
            limits: defaultImageLimits, processor: processor))
        #expect(try dimensions(imageBlock(content.first)) == .init(width: 30, height: 40))
    }

    @Test("converts a format providers do not take inline to PNG")
    func convertsAFormatProvidersDoNotTakeInlineToPNG() async throws {
        let (content, notes) = try fitted(await fitImages(content: [image(bmp(4, 4), "image/bmp")],
            limits: defaultImageLimits, processor: processor))
        #expect(try imageBlock(content.first).mimeType == "image/png")
        #expect(notes == ["Converted from image/bmp to image/png."])
    }

    @Test("corrects a declared type the bytes contradict, without a note")
    func correctsADeclaredTypeTheBytesContradictWithoutANote() async throws {
        let jpeg = try fixture(8, 6, jpeg: true)
        let (content, notes) = try fitted(await fitImages(content: [image(jpeg, "image/png")],
            limits: defaultImageLimits, processor: processor))
        let result = try imageBlock(content.first)
        #expect(result.mimeType == "image/jpeg"); #expect(result.data == toBase64(jpeg)); #expect(notes.isEmpty)
    }

    @Test("leaves out what cannot be prepared, with a note: damaged images, other bytes, malformed base64")
    func leavesOutWhatCannotBePreparedWithANoteDamagedImagesOtherBytesMalformedBase64() async throws {
        let note = "An image (image/png) cannot be prepared for the model and was left out."
        for bytes in [Array(try fixture(4, 4).prefix(40)), Array("not an image at all, though it says so".utf8)] {
            let (content, notes) = try fitted(await fitImages(content: [.text(.init(text: "a")), image(bytes, "image/png")],
                limits: defaultImageLimits, processor: processor))
            #expect(content.count == 1); #expect(notes == [note])
        }
        let malformed = ContentBlock.image(.init(data: "%%%", mimeType: "image/png"))
        let (content, notes) = try fitted(await fitImages(content: [malformed], limits: defaultImageLimits, processor: processor))
        #expect(content.isEmpty)
        #expect(notes.count == 1 && notes[0].hasPrefix("An image (image/png) cannot be prepared for the model and was left out: "))
    }

    @Test("fits a tool result's images to the conversation model's limits before it is committed")
    func fitsAToolResultsImagesToTheConversationModelsLimitsBeforeItIsCommitted() async throws {
        let setup = HarnessChatSetup()
        let wide = try fixture(400, 100)
        let small = try fixture(8, 6)
        let tool = try ToolRegistration(name: "picture", description: "A picture", parameters: ["type": "object"]) { args, _, _ in
            let id = args["id"]?.stringValue
            if id == "small" { return .init(output: [.image(.init(data: toBase64(small), mimeType: "image/png"))]) }
            return .init(output: [.text(.init(text: "here")), .image(.init(data: toBase64(wide), mimeType: "image/png"))],
                         diagnostics: [.init(severity: .info, message: "the tool's own")])
        }
        try setup.registry.install(Extension(name: "pictures", tools: [tool]))
        try setup.registry.install(createFitImagesExtension(processor: processor))
        setup.models.setResponses([.message(try toolCalls([
            ("picture", ["id": "wide"], "wide"), ("picture", ["id": "small"], "small")
        ])), .message(chatAssistant("done"))])
        let models = LimitedFitModels(base: setup.models, maxWidth: 100)
        let opened = try await openChat(setup: setup, models: models)
        _ = try await opened.root.submit(.input(content: .text("show")), context: .background).wait(context: .background)
        let entries = try await allEntries(opened.root)
        let results = try harnessToolResults(entries)
        let wideResult = try #require(results.first { $0.toolCallId == "wide" })
        let smallResult = try #require(results.first { $0.toolCallId == "small" })
        #expect(wideResult.content.count == 3)
        #expect(try dimensions(imageBlock(wideResult.content[1])) == .init(width: 100, height: 25))
        guard case .text(let info) = wideResult.content[2] else { Issue.record("Missing diagnostic text"); return }
        #expect(info.text == "<harness>\n[info] the tool's own\n[info] Resized from 400x100 to 100x25. Multiply coordinates by 4.00 to map them to the original.\n</harness>")
        #expect(smallResult.content.count == 1)
        #expect(try imageBlock(smallResult.content.first).data == toBase64(small))
        try await opened.harness.close(context: .background)
    }

    @Test("leaves nested calls' results to the program that made them")
    func leavesNestedCallsResultsToTheProgramThatMadeThem() async throws {
        let registration = try #require(createFitImagesExtension(processor: processor).hooks.first)
        #expect(registration.task == "pi.tool")
        let hooks = try #require(registration.handlers(as: ToolHooks.self))
        let afterTool = try #require(hooks.afterTool)
        let call = ToolHookCall(ToolCall(id: "n", name: "picture", arguments: [:]),
            parent: .init(taskId: try TaskID(1), callId: "c"))
        let result = ToolExecutionResult(output: [image(try fixture(400, 10), "image/png")])
        let api = HookApi(taskId: try TaskID(2), conversationId: rootConversationID, models: FakeDurableModels())
        #expect(try await afterTool(call, result, api, .background) == nil)
    }

    @Test("example 47: fits a user photo and a screenshot before storing them")
    func example47FitImages() async throws {
        let setup = HarnessChatSetup()
        let screenshot = try fixture(3000, 1000, grey: true)
        let tool = try ToolRegistration(name: "screenshot", description: "Screenshot", parameters: ["type": "object"]) { _, _, _ in
            .init(output: [.image(.init(data: toBase64(screenshot), mimeType: "image/png"))])
        }
        try setup.registry.install(Extension(name: "screenshot", tools: [tool]))
        try setup.registry.install(createFitImagesExtension(processor: processor))
        setup.models.setResponses([.message(try toolCalls([("screenshot", [:], "screenshot-1")])),
                                   .message(chatAssistant("Both look grey."))])
        let models = LimitedFitModels(base: setup.models, maxWidth: 1000)
        let photo = try fixture(4000, 3000, grey: true)
        let fittedPhoto = await fitImage(bytes: photo, mimeType: "image/png", limits: imageLimits(models.getModel(provider: "faux", modelId: "faux-1")), processor: processor)
        guard case .fitted(let attachment, let notes) = fittedPhoto else { Issue.record("Photo omitted"); return }
        #expect(try dimensions(attachment) == .init(width: 1000, height: 750))
        #expect(notes == ["Resized from 4000x3000 to 1000x750. Multiply coordinates by 4.00 to map them to the original."])
        let opened = try await openChat(setup: setup, models: models)
        let input: [ContentBlock] = [.text(.init(text: "Compare the photo and screenshot.\n" + notes.joined(separator: " "))), .image(attachment)]
        _ = try await opened.root.submit(.input(content: .blocks(input)), context: .background).wait(context: .background)
        let entries = try await allEntries(opened.root)
        let result = try #require(harnessToolResults(entries).first)
        #expect(try dimensions(imageBlock(result.content.first)) == .init(width: 1000, height: 333))
        #expect(entries.contains { $0.model?.first?["content"]?[1]?["type"] == "image" })
        try await opened.harness.close(context: .background)
    }
}

private enum FitTestError: Error { case notFitted, noImage }
private struct FailingFitProcessor: ImageProcessor {
    func prepare(bytes: [UInt8], mimeType: String, limits: ImageLimits) async throws -> PreparedImage? {
        throw FitFailure()
    }
}
private struct FitFailure: Error, CustomStringConvertible { var description: String { "worker exited" } }
private actor RecordingFitProcessor: ImageProcessor {
    let base: NativeImageProcessor
    private(set) var calls: [String] = []
    init(base: NativeImageProcessor) { self.base = base }
    func prepare(bytes: [UInt8], mimeType: String, limits: ImageLimits) async throws -> PreparedImage? {
        calls.append(mimeType)
        return try await base.prepare(bytes: bytes, mimeType: mimeType, limits: limits)
    }
}

private struct LimitedFitModels: DurableModels {
    let base: FakeDurableModels
    let maxWidth: Int
    func getModel(provider: String, modelId: String) -> Model? {
        guard let model = base.getModel(provider: provider, modelId: modelId) else { return nil }
        return Model(id: model.id, name: model.name, api: model.api, provider: model.provider,
            baseUrl: model.baseUrl, reasoning: model.reasoning, input: model.input, cost: model.cost,
            contextWindow: model.contextWindow, maxTokens: model.maxTokens,
            inputLimits: .init(images: .init(resize: .init(maxWidth: maxWidth))))
    }
    func streamSimple(model: Model, context: PiSwiftAI.Context,
                      options: SimpleStreamOptions) -> AssistantMessageEventStream {
        base.streamSimple(model: model, context: context, options: options)
    }
}

private func fixture(_ width: Int, _ height: Int, jpeg: Bool = false, noise: Bool = false,
                     grey: Bool = false) throws -> [UInt8] {
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    var seed: UInt32 = 1
    for index in 0..<(width * height) {
        let offset = index * 4
        for channel in 0..<3 {
            if noise {
                // Match JavaScript's rounded Number arithmetic before >>> 0.
                seed = UInt32((Double(seed) * 1_103_515_245 + 12_345)
                    .truncatingRemainder(dividingBy: 4_294_967_296))
                pixels[offset + channel] = UInt8(truncatingIfNeeded: seed >> 24)
            } else { pixels[offset + channel] = grey ? 128 : (channel == 0 ? 255 : 0) }
        }
    }
    if !grey && !noise { pixels[0] = 0; pixels[1] = 255; pixels[2] = 0 }
    let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
    let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8,
        bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data,
        (jpeg ? "public.jpeg" : "public.png") as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return Array(data as Data)
}

private func bmp(_ width: Int, _ height: Int) -> [UInt8] {
    let row = ((width * 3 + 3) / 4) * 4
    var bytes = [UInt8](repeating: 0, count: 54 + row * height)
    func put(_ value: Int, _ offset: Int, _ count: Int) {
        for index in 0..<count { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }
    bytes[0] = 0x42; bytes[1] = 0x4d
    put(bytes.count, 2, 4); put(54, 10, 4); put(40, 14, 4)
    put(width, 18, 4); put(height, 22, 4); put(1, 26, 2); put(24, 28, 2); put(row * height, 34, 4)
    for y in 0..<height { for x in 0..<width { bytes[54 + y * row + x * 3 + 2] = 255 } }
    return bytes
}

private func oriented(_ jpeg: [UInt8]) -> [UInt8] {
    let tiff: [UInt8] = [0x4d, 0x4d, 0, 42, 0, 0, 0, 8, 0, 1, 1, 0x12, 0, 3,
                         0, 0, 0, 1, 0, 6, 0, 0, 0, 0, 0, 0]
    let exif: [UInt8] = [0x45, 0x78, 0x69, 0x66, 0, 0] + tiff
    let app1: [UInt8] = [0xff, 0xe1, UInt8((exif.count + 2) >> 8), UInt8((exif.count + 2) & 255)] + exif
    return Array(jpeg.prefix(2)) + app1 + jpeg.dropFirst(2)
}
#endif
