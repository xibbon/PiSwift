import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftCodingAgent

public final class FooterComponent: Component {
    private let session: AgentSession
    private var autoCompactEnabled = true
    private let footerData: FooterDataProviding
    private var bashToolStartDate: Date?

    public init(session: AgentSession, footerData: FooterDataProviding) {
        self.session = session
        self.footerData = footerData
    }

    public func setBashToolRunning(_ running: Bool) {
        bashToolStartDate = running ? Date() : nil
    }

    public func setAutoCompactEnabled(_ enabled: Bool) {
        autoCompactEnabled = enabled
    }

    public func invalidate() {
        // Branch cache invalidation handled by FooterDataProvider.
    }

    public func render(width: Int) -> [String] {
        let state = session.agent.state

        var totalInput = 0
        var totalOutput = 0
        var totalCacheRead = 0
        var totalCacheWrite = 0
        var totalCost: Double = 0

        for entry in session.sessionManager.getEntries() {
            if case let .message(messageEntry) = entry,
               case let .assistant(message) = messageEntry.message {
                totalInput += message.usage.input
                totalOutput += message.usage.output
                totalCacheRead += message.usage.cacheRead
                totalCacheWrite += message.usage.cacheWrite
                totalCost += message.usage.cost.total
            }
        }

        let lastAssistant = state.messages.reversed().compactMap { message -> AssistantMessage? in
            if case let .assistant(assistant) = message, assistant.stopReason != .aborted {
                return assistant
            }
            return nil
        }.first

        let contextTokens = lastAssistant.map { $0.usage.input + $0.usage.output + $0.usage.cacheRead + $0.usage.cacheWrite } ?? 0
        let contextWindow = state.model.contextWindow
        let contextPercentValue = contextWindow > 0 ? (Double(contextTokens) / Double(contextWindow)) * 100.0 : 0.0
        let contextPercent = String(format: "%.1f", contextPercentValue)

        let formatTokens: (Int) -> String = { count in
            if count < 1000 { return "\(count)" }
            if count < 10000 { return String(format: "%.1fk", Double(count) / 1000.0) }
            if count < 1_000_000 { return "\(Int(round(Double(count) / 1000.0)))k" }
            if count < 10_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000.0) }
            return "\(Int(round(Double(count) / 1_000_000.0)))M"
        }

        var pwd = FileManager.default.currentDirectoryPath
        if let home = ProcessInfo.processInfo.environment["HOME"], pwd.hasPrefix(home) {
            pwd = "~" + pwd.dropFirst(home.count)
        }

        if let branch = footerData.getGitBranch() {
            pwd += " (\(branch))"
        }

        if visibleWidth(pwd) > width {
            pwd = truncateToWidth(pwd, maxWidth: width, ellipsis: "...")
        }

        var statsParts: [String] = []
        if totalInput > 0 { statsParts.append("↑\(formatTokens(totalInput))") }
        if totalOutput > 0 { statsParts.append("↓\(formatTokens(totalOutput))") }
        if totalCacheRead > 0 { statsParts.append("R\(formatTokens(totalCacheRead))") }
        if totalCacheWrite > 0 { statsParts.append("W\(formatTokens(totalCacheWrite))") }
        if totalCost > 0 {
            statsParts.append(String(format: "$%.3f", totalCost))
        }

        let autoIndicator = autoCompactEnabled ? " (auto)" : ""
        let contextDisplay = "\(contextPercent)%/\(formatTokens(contextWindow))\(autoIndicator)"
        let contextText: String
        if contextPercentValue > 90 {
            contextText = theme.fg(.error, contextDisplay)
        } else if contextPercentValue > 70 {
            contextText = theme.fg(.warning, contextDisplay)
        } else {
            contextText = contextDisplay
        }
        statsParts.append(contextText)

        var statsLeft = statsParts.joined(separator: " ")
        let modelName = state.model.id
        var rightSide = modelName
        if state.model.reasoning {
            let thinking = state.thinkingLevel.rawValue
            if thinking != "off" {
                rightSide = "\(modelName) • \(thinking)"
            }
        }

        var statsLeftWidth = visibleWidth(statsLeft)
        let rightSideWidth = visibleWidth(rightSide)

        if statsLeftWidth > width {
            let plain = stripAnsi(statsLeft)
            statsLeft = String(plain.prefix(max(0, width - 3))) + "..."
            statsLeftWidth = visibleWidth(statsLeft)
        }

        let minPadding = 2
        let totalNeeded = statsLeftWidth + minPadding + rightSideWidth
        let statsLine: String
        if totalNeeded <= width {
            let padding = String(repeating: " ", count: width - statsLeftWidth - rightSideWidth)
            statsLine = statsLeft + padding + rightSide
        } else {
            let availableForRight = width - statsLeftWidth - minPadding
            if availableForRight > 3 {
                let plain = stripAnsi(rightSide)
                let truncated = String(plain.prefix(availableForRight))
                let padding = String(repeating: " ", count: max(0, width - statsLeftWidth - truncated.count))
                statsLine = statsLeft + padding + truncated
            } else {
                statsLine = statsLeft
            }
        }

        let dimStatsLeft = theme.fg(.dim, statsLeft)
        let remainder = statsLine.dropFirst(statsLeft.count)
        let dimRemainder = theme.fg(.dim, String(remainder))

        var lines = [theme.fg(.dim, pwd), dimStatsLeft + dimRemainder]

        let extensionStatuses = footerData.getExtensionStatuses()
        if !extensionStatuses.isEmpty {
            let sortedStatuses = extensionStatuses.keys.sorted().compactMap { key in
                extensionStatuses[key].map(sanitizeStatusText)
            }
            let statusLine = sortedStatuses.joined(separator: " ")
            lines.append(truncateToWidth(statusLine, maxWidth: width, ellipsis: theme.fg(.dim, "...")))
        }

        if let startDate = bashToolStartDate {
            let elapsed = Int(Date().timeIntervalSince(startDate))
            let elapsedText = theme.fg(.bashMode, "bash \(elapsed)s")
            lines.append(elapsedText)
        }

        return lines
    }
}

private func sanitizeStatusText(_ text: String) -> String {
    text
        .replacingOccurrences(of: "[\r\n\t]", with: " ", options: .regularExpression)
        .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func stripAnsi(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{001B}\\[[0-9;]*m", with: "", options: .regularExpression)
}
