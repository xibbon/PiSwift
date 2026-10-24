import Foundation
import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftCodingAgent
@testable import PiSwiftCodingAgentDurable
import PiSwiftDurable
import PiSwiftDurableTesting

#if canImport(ImageIO) && canImport(CoreGraphics)
import CoreGraphics
import ImageIO

@Suite("PiSwiftCodingAgentDurableTests.HostImages")
struct HostImageTests {
    // Both host registry paths must pass the processor to the installed read tool.
    private func read(_ bytes: Data, name: String, agentDirectory: Bool) async throws -> ToolResultMessage {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("e12-image-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try bytes.write(to: directory.appendingPathComponent(name))
        var call = chatAssistant("", reason: .toolUse)
        call.content = [.toolCall(.init(id: "image-read", name: "read", arguments: ["path": AnyCodable(name)]))]
        let models = FakeDurableModels(options: .init(models: [
            .init(id: "faux-1", input: [.text, .image])
        ]), responses: [.message(call), .message(chatAssistant("Image read"))])
        if agentDirectory {
            let agent = directory.appendingPathComponent("agent")
            try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
            let session = try await openDurable(.init(cwd: directory.path), dependencies: .init(
                agentDirectory: agent.path, makeModels: { _ in
                    DurableRuntimeModels(models: models, available: models.models, initial: { _ in
                        InitialAgentModel(model: .init(provider: "faux", modelId: "faux-1"))
                    })
                }))
            do {
                await session.controller.submit("Read the image", whenBusy: .followUp)
                let deadline = ContinuousClock.now.advanced(by: .seconds(10))
                while !session.view.current().conversation.entries.contains(where: { entry in
                    (try? entry.messages()?.contains { textOf($0) == "Image read" }) == true
                }) {
                    guard ContinuousClock.now < deadline else { throw CancellationError() }
                    try await Task.sleep(for: .milliseconds(10))
                }
                let result = try result(session.view.current().conversation.entries)
                #expect(session.failure == nil)
                await session.close()
                return result
            } catch {
                await session.close()
                throw error
            }
        }
        let registry = try createCodingRegistry(settingsManager: .inMemory(), cwd: directory.path)
        let harness = try await Harness.open(storage: MemoryStorage(), options: .init(
            models: models, registry: registry,
            env: { _, _ in LocalExecutionEnv(cwd: directory.path) }), context: .background)
        do {
            let root = try await harness.root(options: .init(agent: .init(
                model: .set(.init(provider: "faux", modelId: "faux-1")), cwd: .set(directory.path))), context: .background)
            let outcome = try await root.submit(.input(content: .text("Read the image")), context: .background)
                .wait(context: .background)
            #expect(outcome.status == "done")
            let result = try result(await allEntries(root))
            try await harness.close(context: .background)
            return result
        } catch {
            try? await harness.close(context: .background)
            throw error
        }
    }

    private func result(_ entries: [EntryRecord]) throws -> ToolResultMessage {
        let entry = try #require(entries.first { $0.kind == "pi.tool-result" })
        let message = try #require(entry.messages()?.first)
        guard case .toolResult(let result) = message else { throw CancellationError() }
        #expect(!result.isError)
        return result
    }

    private func image(_ result: ToolResultMessage) throws -> (ImageContent, CGImage) {
        let images = result.content.compactMap { block -> ImageContent? in
            if case .image(let image) = block { return image }
            return nil
        }
        #expect(images.count == 1)
        let image = try #require(images.first)
        let data = try #require(Data(base64Encoded: image.data))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return (image, try #require(CGImageSourceCreateImageAtIndex(source, 0, nil)))
    }

    @Test(arguments: [false, true])
    func oversizedPNGIsShrunkWithinModelLimits(agentDirectory: Bool) async throws {
        let original = try png(width: 4000, height: 1000)
        let (block, decoded) = try image(await read(original, name: "wide.png", agentDirectory: agentDirectory))
        #expect(decoded.width == 2000)
        #expect(decoded.height == 500)
        #expect(decoded.width <= defaultImageLimits.maxWidth)
        #expect(decoded.height <= defaultImageLimits.maxHeight)
        #expect(block.data.utf8.count <= defaultImageLimits.maxBytes)
        #expect(block.mimeType == "image/png")
        #expect(Data(base64Encoded: block.data) != original)
    }

    @Test(arguments: [false, true])
    func bmpIsConvertedToPNG(agentDirectory: Bool) async throws {
        let original = bmp()
        let (block, decoded) = try image(await read(original, name: "small.bmp", agentDirectory: agentDirectory))
        #expect(block.mimeType == "image/png")
        #expect(decoded.width == 4)
        #expect(decoded.height == 4)
        let data = try #require(Data(base64Encoded: block.data))
        #expect(Array(data.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10])
        #expect(data != original)
    }

    private func png(width: Int, height: Int) throws -> Data {
        let pixels = Data(repeating: 255, count: width * height * 4)
        let provider = try #require(CGDataProvider(data: pixels as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func bmp() -> Data {
        var bytes = [UInt8](repeating: 0, count: 102)
        func put(_ value: Int, at: Int, count: Int) {
            for index in 0..<count { bytes[at + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
        }
        bytes[0] = 0x42; bytes[1] = 0x4d
        put(bytes.count, at: 2, count: 4); put(54, at: 10, count: 4)
        put(40, at: 14, count: 4); put(4, at: 18, count: 4); put(4, at: 22, count: 4)
        put(1, at: 26, count: 2); put(24, at: 28, count: 2); put(48, at: 34, count: 4)
        for pixel in 0..<16 { bytes[54 + pixel * 3 + 2] = 255 }
        return Data(bytes)
    }
}
#endif
