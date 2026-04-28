import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftCodingAgent

private let OSC133_ZONE_START = "\u{001B}]133;A\u{0007}"
private let OSC133_ZONE_END = "\u{001B}]133;B\u{0007}"
private let OSC133_ZONE_FINAL = "\u{001B}]133;C\u{0007}"

public final class AssistantMessageComponent: Container {
    private let contentContainer: Container
    private var hideThinkingBlock: Bool
    private var lastMessage: AssistantMessage?
    private var hasToolCalls: Bool = false

    public init(message: AssistantMessage? = nil, hideThinkingBlock: Bool = false) {
        self.contentContainer = Container()
        self.hideThinkingBlock = hideThinkingBlock
        super.init()
        addChild(contentContainer)
        if let message {
            updateContent(message)
        }
    }

    public override func invalidate() {
        super.invalidate()
        if let lastMessage {
            updateContent(lastMessage)
        }
    }

    public override func render(width: Int) -> [String] {
        var lines = super.render(width: width)
        if hasToolCalls || lines.isEmpty {
            return lines
        }
        lines[0] = OSC133_ZONE_START + lines[0]
        lines[lines.count - 1] = OSC133_ZONE_END + OSC133_ZONE_FINAL + lines[lines.count - 1]
        return lines
    }

    public func setHideThinkingBlock(_ hide: Bool) {
        hideThinkingBlock = hide
    }

    public func updateContent(_ message: AssistantMessage) {
        lastMessage = message
        contentContainer.clear()

        let hasContent = message.content.contains { block in
            switch block {
            case .text(let text):
                return !text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .thinking(let thinking):
                return !thinking.thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            default:
                return false
            }
        }

        if hasContent {
            contentContainer.addChild(Spacer(1))
        }

        for (index, block) in message.content.enumerated() {
            switch block {
            case .text(let textContent):
                let trimmed = textContent.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                contentContainer.addChild(Markdown(trimmed, paddingX: 1, paddingY: 0, theme: getMarkdownTheme()))
            case .thinking(let thinkingContent):
                let trimmed = thinkingContent.thinking.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                let hasTextAfter = message.content.suffix(from: index + 1).contains { block in
                    if case let .text(text) = block {
                        return !text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }
                    return false
                }

                if hideThinkingBlock {
                    contentContainer.addChild(Text(theme.italic(theme.fg(.thinkingText, "Thinking...")), paddingX: 1, paddingY: 0))
                    if hasTextAfter {
                        contentContainer.addChild(Spacer(1))
                    }
                } else {
                    let style = DefaultTextStyle(color: { theme.fg(.thinkingText, $0) }, italic: true)
                    contentContainer.addChild(Markdown(trimmed, paddingX: 1, paddingY: 0, theme: getMarkdownTheme(), defaultTextStyle: style))
                    contentContainer.addChild(Spacer(1))
                }
            default:
                continue
            }
        }

        let hasToolCalls = message.content.contains { block in
            if case .toolCall = block {
                return true
            }
            return false
        }
        self.hasToolCalls = hasToolCalls

        if !hasToolCalls {
            switch message.stopReason {
            case .aborted:
                contentContainer.addChild(Text(theme.fg(.error, "\nAborted"), paddingX: 1, paddingY: 0))
            case .error:
                let errorMsg = message.errorMessage ?? "Unknown error"
                contentContainer.addChild(Spacer(1))
                contentContainer.addChild(Text(theme.fg(.error, "Error: \(errorMsg)"), paddingX: 1, paddingY: 0))
            default:
                break
            }
        }
    }
}
