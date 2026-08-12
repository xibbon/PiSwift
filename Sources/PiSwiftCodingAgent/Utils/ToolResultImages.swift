import PiSwiftAI

struct NormalizedToolResultContent: Sendable {
    var content: [ContentBlock]
    var changed: Bool
}

/// Resizes oversized images as they enter tool-result history. Images added by
/// extension hooks are included because AgentSession calls this after the hook.
func normalizeToolResultImages(
    _ content: [ContentBlock],
    autoResizeImages: Bool = true
) -> NormalizedToolResultContent {
    guard autoResizeImages, content.contains(where: {
        if case .image = $0 { return true }
        return false
    }) else {
        return NormalizedToolResultContent(content: content, changed: false)
    }

    var normalized: [ContentBlock] = []
    var changed = false
    for block in content {
        guard case .image(let image) = block else {
            normalized.append(block)
            continue
        }

        let resized = resizeImage(image)
        guard resized.wasResized else {
            normalized.append(block)
            continue
        }

        normalized.append(.image(ImageContent(data: resized.data, mimeType: resized.mimeType)))
        if let note = formatDimensionNote(resized) {
            normalized.append(.text(TextContent(text: note)))
        }
        changed = true
    }
    return NormalizedToolResultContent(content: changed ? normalized : content, changed: changed)
}
