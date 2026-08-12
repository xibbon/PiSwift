/// Extracts text blocks and joins them with `separator`.
public func contentText(_ content: [ContentBlock], separator: String = "\n") -> String {
    content.compactMap { block in
        guard case .text(let text) = block else { return nil }
        return text.text
    }.joined(separator: separator)
}

/// Extracts text from user message content.
public func contentText(_ content: UserContent, separator: String = "\n") -> String {
    switch content {
    case .text(let text):
        return text
    case .blocks(let blocks):
        return contentText(blocks, separator: separator)
    }
}

/// Returns string content unchanged.
public func contentText(_ content: String, separator _: String = "\n") -> String {
    content
}
