import Foundation
import PiSwiftAI
import PiSwiftChord

/// One prepared image, or the reason it was left out.
public enum FittedImage: Sendable {
    case fitted(image: ImageContent, notes: [String])
    case omitted(note: String)
}

/// The result of fitting images in content blocks.
public enum FittedImages: Sendable {
    case unchanged
    case fitted(content: [ContentBlock], notes: [String])
}

/// Decode and prepare an image before it enters a conversation.
public func fitImage(bytes: [UInt8], mimeType: String, limits: ImageLimits,
                     processor: any ImageProcessor) async -> FittedImage {
    let prepared: PreparedImage?
    do {
        prepared = try await processor.prepare(bytes: bytes,
            mimeType: detectSupportedImageMimeType(bytes) ?? mimeType, limits: limits)
    } catch {
        return omittedImage(mimeType: mimeType, reason: ": \(error)")
    }
    guard let prepared else { return omittedImage(mimeType: mimeType, reason: "") }
    return .fitted(image: ImageContent(data: prepared.data, mimeType: prepared.mimeType),
                   notes: preparedNotes(prepared))
}

private func omittedImage(mimeType: String, reason: String) -> FittedImage {
    .omitted(note: "An image (\(mimeType)) cannot be prepared for the model and was left out\(reason).")
}

/// Fit every image in the content; leave text in its original position.
public func fitImages(content: [ContentBlock], limits: ImageLimits,
                      processor: any ImageProcessor) async -> FittedImages {
    var output: [ContentBlock] = []
    var notes: [String] = []
    var changed = false
    for item in content {
        guard case .image(let image) = item else { output.append(item); continue }
        let fitted: FittedImage
        do {
            fitted = await fitImage(bytes: try fromBase64(image.data), mimeType: image.mimeType,
                                    limits: limits, processor: processor)
        } catch {
            fitted = omittedImage(mimeType: image.mimeType, reason: ": \(error)")
        }
        switch fitted {
        case .omitted(let note):
            changed = true
            notes.append(note)
        case .fitted(let prepared, let imageNotes):
            if prepared.data == image.data && prepared.mimeType == image.mimeType {
                output.append(item)
            } else {
                changed = true
                output.append(.image(prepared))
                notes.append(contentsOf: imageNotes)
            }
        }
    }
    return changed ? .fitted(content: output, notes: notes) : .unchanged
}

/// Fit images in model-facing tool results before the results are committed.
public func createFitImagesExtension(processor: any ImageProcessor) -> Extension {
    Extension(name: "fit-images", hooks: [hook(ToolHooks(afterTool: { call, result, api, context in
        try await fitResult(call: call, result: result, processor: processor, api: api, context: context)
    }))])
}

private func fitResult(call: ToolHookCall, result: ToolExecutionResult, processor: any ImageProcessor,
                       api: HookApi, context: ChordContext) async throws -> ToolExecutionResult? {
    guard call.parent == nil, let output = result.output,
          output.contains(where: { if case .image = $0 { return true }; return false }) else { return nil }
    let ref = try await api.read.snapshot(AgentDoc, conversationId: api.conversationId, context: context)?.model
    let model = ref.flatMap { api.models.getModel(provider: $0.provider, modelId: $0.modelId) }
    switch await fitImages(content: output, limits: imageLimits(model), processor: processor) {
    case .unchanged: return nil
    case .fitted(let content, let notes):
        var fitted = result
        fitted.output = content
        if !notes.isEmpty {
            fitted.diagnostics = (result.diagnostics ?? []) + [
                ToolDiagnostic(severity: .info, message: notes.joined(separator: " "), code: "image")
            ]
        }
        return fitted
    }
}
