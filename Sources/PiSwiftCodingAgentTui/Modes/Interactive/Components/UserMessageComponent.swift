import Foundation
import MiniTui
import PiSwiftCodingAgent

private let OSC133_ZONE_START = "\u{001B}]133;A\u{0007}"
private let OSC133_ZONE_END = "\u{001B}]133;B\u{0007}"
private let OSC133_ZONE_FINAL = "\u{001B}]133;C\u{0007}"

public final class UserMessageComponent: Container {
    public init(text: String) {
        super.init()
        addChild(Spacer(1))
        let style = DefaultTextStyle(
            color: { theme.fg(.userMessageText, $0) },
            bgColor: { theme.bg(.userMessageBg, $0) }
        )
        addChild(Markdown(text, paddingX: 1, paddingY: 1, theme: getMarkdownTheme(), defaultTextStyle: style))
    }

    public override func render(width: Int) -> [String] {
        var lines = super.render(width: width)
        if lines.isEmpty { return lines }
        lines[0] = OSC133_ZONE_START + lines[0]
        lines[lines.count - 1] = OSC133_ZONE_END + OSC133_ZONE_FINAL + lines[lines.count - 1]
        return lines
    }
}
