import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent
#if canImport(AppKit)
import AppKit
#endif

@Test func c57ModelsJsonLoadsAnthropicFallbacksForCustomModelsAndOverrides() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-c57-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let json = """
    {"providers":{
      "proxy":{"api":"anthropic-messages","baseUrl":"https://example.invalid","models":[
        {"id":"custom","compat":{"allowedFallbackModels":[{"provider":"anthropic","model":"backup","cost":{"input":1,"output":2,"cacheRead":0.1,"cacheWrite":0.2}}]}}
      ]},
      "anthropic":{"modelOverrides":{"claude-sonnet-4-6":{"compat":{"allowedFallbackModels":[]}}}}
    }}
    """
    try json.write(to: directory.appendingPathComponent("models.json"), atomically: true, encoding: .utf8)
    let registry = ModelRegistry(AuthStorage(":memory:"), directory.path)
    let custom = try #require(registry.find("proxy", "custom"))
    #expect(custom.compat?.allowedFallbackModels?.count == 1)
    #expect(custom.compat?.allowedFallbackModels?.first?.model == "backup")
    #expect(custom.compat?.allowedFallbackModels?.first?.cost.output == 2)
    let overridden = try #require(registry.find("anthropic", "claude-sonnet-4-6"))
    #expect(overridden.compat?.allowedFallbackModels == [])
}

@Test func c68BuiltInToolsPreferStrictJsonSchemaWithoutExperimentalFlag() {
    let tools = [createReadTool(cwd: "/"), createBashTool(cwd: "/"), createEditTool(cwd: "/"), createWriteTool(cwd: "/")]
    for tool in tools {
        guard case .jsonSchema(strict: .prefer) = tool.constrainedSampling else {
            Issue.record("\(tool.name) must prefer strict JSON schema sampling")
            continue
        }
        guard case .jsonSchema(strict: .prefer) = tool.aiTool.constrainedSampling else {
            Issue.record("\(tool.name) must forward its sampling mode")
            continue
        }
    }
    for tool in [createGrepTool(cwd: "/"), createFindTool(cwd: "/"), createLsTool(cwd: "/")] {
        #expect(tool.constrainedSampling == nil)
    }
    let extensionOverride = CustomTool(
        name: "read", label: "Extension read", description: "Read files", parameters: [:],
        execute: { _, _, _, _, _ in CustomToolResult(content: []) },
        constrainedSampling: .disabled
    )
    let wrapped = wrapCustomTool(extensionOverride, { preconditionFailure("Tool is not executed in this test") })
    guard case .disabled = wrapped.aiTool.constrainedSampling else {
        Issue.record("An extension must be able to disable constrained sampling")
        return
    }
}

#if canImport(AppKit)
private func c4Png() throws -> Data {
    let bitmap = try #require(NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 100,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ))
    return try #require(bitmap.representation(using: .png, properties: [:]))
}

private func c4ImageWidth(_ image: ImageContent) -> Int {
    resizeImage(image).originalWidth
}

@Test func c13C23ImageCallersUseModelResizeProfile() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-c13-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let png = try c4Png()
    let path = directory.appendingPathComponent("image.png")
    try png.write(to: path)
    let profile = ModelImageResizeOptions(maxWidth: 20, maxHeight: 20)
    let model = Model(
        id: "small-images", name: "Small images", api: .anthropicMessages,
        provider: "anthropic", baseUrl: "https://example.invalid", reasoning: false,
        input: [.text, .image], cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 1000, maxTokens: 100,
        inputLimits: ModelInputLimits(images: ModelImageInputLimits(resize: profile))
    )

    let files = try processFileArguments([path.path], options: ProcessFileOptions(resizeOptions: profile))
    let attachment = try #require(files.imageAttachments.first)
    #expect(c4ImageWidth(attachment) <= 20)
    #expect(files.textContent.contains("original 100x100"))
    let ordinaryFiles = try processFileArguments([path.path])
    #expect(c4ImageWidth(try #require(ordinaryFiles.imageAttachments.first)) == 100)

    let read = createReadTool(cwd: directory.path)
    let execute = try #require(read.executeWithContext)
    let readResult = try await execute("read", ["path": AnyCodable(path.path)], nil, nil, AgentToolExecutionContext(cwd: directory.path, model: model))
    let readImages = readResult.content.compactMap { block -> ImageContent? in
        if case .image(let image) = block { return image }
        return nil
    }
    #expect(readImages.count == 1)
    #expect(readImages.allSatisfy { c4ImageWidth($0) <= 20 })
    let ordinaryRead = try await read.execute("ordinary-read", ["path": AnyCodable(path.path)], nil, nil)
    #expect(ordinaryRead.content.contains { block in
        if case .image(let image) = block { return c4ImageWidth(image) == 100 }
        return false
    })
    let currentModel = LockedState<Model?>(nil)
    let dynamicRead = createReadTool(cwd: directory.path, options: ReadToolOptions(modelProvider: {
        currentModel.withLock { $0 }
    }))
    currentModel.withLock { $0 = model }
    let switchedResult = try await dynamicRead.execute("switched-read", ["path": AnyCodable(path.path)], nil, nil)
    #expect(switchedResult.content.contains { block in
        if case .image(let image) = block { return c4ImageWidth(image) <= 20 }
        return false
    })

    let toolResult = normalizeToolResultImages([.image(ImageContent(data: png.base64EncodedString(), mimeType: "image/png"))], resizeOptions: profile)
    #expect(toolResult.changed)
    let toolImages = toolResult.content.compactMap { block -> ImageContent? in
        if case .image(let image) = block { return image }
        return nil
    }
    #expect(toolImages.count == 1)
    #expect(toolImages.allSatisfy { c4ImageWidth($0) <= 20 })
    let ordinaryToolResult = normalizeToolResultImages([.image(ImageContent(data: png.base64EncodedString(), mimeType: "image/png"))])
    #expect(!ordinaryToolResult.changed)

    let impossible = ModelImageResizeOptions(maxBytes: 1)
    let omittedFile = try processFileArguments([path.path], options: ProcessFileOptions(resizeOptions: impossible))
    #expect(omittedFile.imageAttachments.isEmpty)
    #expect(omittedFile.textContent.contains("Image omitted"))
    let omittedRead = try await createReadTool(cwd: directory.path, options: ReadToolOptions(resizeOptions: impossible))
        .execute("omitted-read", ["path": AnyCodable(path.path)], nil, nil)
    #expect(!omittedRead.content.contains { if case .image = $0 { return true }; return false })
    let preservedTool = normalizeToolResultImages([.image(ImageContent(data: png.base64EncodedString(), mimeType: "image/png"))], resizeOptions: impossible)
    #expect(!preservedTool.changed)
}
#endif
