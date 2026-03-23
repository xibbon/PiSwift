import Foundation
import MiniTui
import PiSwiftCodingAgent

private enum SessionScope: String {
    case current
    case all
}

public typealias SessionsLoader = @Sendable (_ onProgress: SessionListProgress?) async -> [SessionInfo]

/// Shortens a path by replacing the home directory with ~
func shortenPath(_ path: String) -> String {
    let home = NSHomeDirectory()
    guard !path.isEmpty else { return path }
    if path.hasPrefix(home) {
        return "~" + path.dropFirst(home.count)
    }
    return path
}

/// Formats a session date as a relative time string
func formatSessionDate(_ date: Date) -> String {
    formatSessionDate(date, relativeTo: Date())
}

/// Formats a session date as a relative time string, relative to a reference date
func formatSessionDate(_ date: Date, relativeTo now: Date) -> String {
    let diff = now.timeIntervalSince(date)
    let diffMins = Int(diff / 60)
    let diffHours = Int(diff / 3600)
    let diffDays = Int(diff / 86400)

    if diffMins < 1 { return "just now" }
    if diffMins < 60 { return "\(diffMins) minute\(diffMins == 1 ? "" : "s") ago" }
    if diffHours < 24 { return "\(diffHours) hour\(diffHours == 1 ? "" : "s") ago" }
    if diffDays == 1 { return "1 day ago" }
    if diffDays < 7 { return "\(diffDays) days ago" }

    let formatter = DateFormatter()
    formatter.dateStyle = .short
    return formatter.string(from: date)
}

private final class SessionSelectorHeader: Component {
    private var scope: SessionScope
    private var loading = false
    private var loadProgress: (loaded: Int, total: Int)?

    init(scope: SessionScope) {
        self.scope = scope
    }

    func setScope(_ scope: SessionScope) {
        self.scope = scope
    }

    func setLoading(_ loading: Bool) {
        self.loading = loading
        if !loading {
            loadProgress = nil
        }
    }

    func setProgress(loaded: Int, total: Int) {
        loadProgress = (loaded, total)
    }

    func invalidate() {}

    func render(width: Int) -> [String] {
        let title = scope == .current ? "Resume Session (Current Folder)" : "Resume Session (All)"
        let leftText = theme.bold(title)
        let scopeText: String
        if loading {
            let progressText = loadProgress.map { "\($0.loaded)/\($0.total)" } ?? "..."
            scopeText = theme.fg(.muted, "o Current Folder | ") + theme.fg(.accent, "Loading \(progressText)")
        } else {
            scopeText = scope == .current
                ? theme.fg(.accent, "* Current Folder") + theme.fg(.muted, " | o All")
                : theme.fg(.muted, "o Current Folder | ") + theme.fg(.accent, "* All")
        }
        let rightText = truncateToWidth(scopeText, maxWidth: width, ellipsis: "")
        let availableLeft = max(0, width - visibleWidth(rightText) - 1)
        let left = truncateToWidth(leftText, maxWidth: availableLeft, ellipsis: "")
        let spacing = max(0, width - visibleWidth(left) - visibleWidth(rightText))
        let hint = theme.fg(.muted, "Tab to toggle scope")
        return ["\(left)\(String(repeating: " ", count: spacing))\(rightText)", hint]
    }
}

private final class SessionList: Component, SystemCursorAware {
    private var allSessions: [SessionInfo]
    private var filteredSessions: [SessionInfo]
    private var selectedIndex: Int = 0
    private let searchInput: Input
    private var showCwd = false
    var onSelect: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onExit: (() -> Void)?
    var onToggleScope: (() -> Void)?
    private let maxVisible = 5
    var usesSystemCursor: Bool {
        get { searchInput.usesSystemCursor }
        set { searchInput.usesSystemCursor = newValue }
    }

    init(sessions: [SessionInfo], showCwd: Bool) {
        self.allSessions = sessions
        self.filteredSessions = sessions
        self.searchInput = Input()
        self.showCwd = showCwd
        self.searchInput.onSubmit = { [weak self] _ in
            guard let self else { return }
            if let selected = self.filteredSessions[safe: self.selectedIndex] {
                self.onSelect?(selected.path)
            }
        }
    }

    func setSessions(_ sessions: [SessionInfo], showCwd: Bool) {
        allSessions = sessions
        self.showCwd = showCwd
        filterSessions(searchInput.getValue())
    }

    func invalidate() {
        searchInput.invalidate()
    }

    func render(width: Int) -> [String] {
        var lines: [String] = []
        lines.append(contentsOf: searchInput.render(width: width))
        lines.append("")

        if filteredSessions.isEmpty {
            if showCwd {
                lines.append(theme.fg(.muted, "  No sessions found"))
            } else {
                lines.append(theme.fg(.muted, "  No sessions in current folder. Press Tab to view all."))
            }
            return lines
        }

        let startIndex = max(0, min(selectedIndex - maxVisible / 2, filteredSessions.count - maxVisible))
        let endIndex = min(startIndex + maxVisible, filteredSessions.count)

        for i in startIndex..<endIndex {
            let session = filteredSessions[i]
            let isSelected = i == selectedIndex

            let hasName = session.name != nil && !(session.name?.isEmpty ?? true)
            let displayText = session.name ?? session.firstMessage
            let normalizedMessage = displayText.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)

            let cursor = isSelected ? theme.fg(.accent, "> ") : "  "
            let maxMsgWidth = width - 2
            let truncatedMsg = truncateToWidth(normalizedMessage, maxWidth: maxMsgWidth, ellipsis: "...")
            var styledMsg = truncatedMsg
            if hasName {
                styledMsg = theme.fg(.warning, truncatedMsg)
            }
            if isSelected {
                styledMsg = theme.bold(styledMsg)
            }
            let messageLine = cursor + styledMsg

            let modified = formatSessionDate(session.modified)
            let msgCount = "\(session.messageCount) message\(session.messageCount == 1 ? "" : "s")"
            var metadataParts = [modified, msgCount]
            if showCwd, !session.cwd.isEmpty {
                metadataParts.append(shortenPath(session.cwd))
            }
            let metadata = "  " + metadataParts.joined(separator: " · ")
            let metadataLine = theme.fg(.dim, truncateToWidth(metadata, maxWidth: width, ellipsis: ""))

            lines.append(messageLine)
            lines.append(metadataLine)
            lines.append("")
        }

        if startIndex > 0 || endIndex < filteredSessions.count {
            let scrollText = "  (\(selectedIndex + 1)/\(filteredSessions.count))"
            lines.append(theme.fg(.muted, truncateToWidth(scrollText, maxWidth: width, ellipsis: "")))
        }

        return lines
    }

    func handleInput(_ keyData: String) {
        let kb = getKeybindings()
        if kb.matches(keyData, TUIKeybinding.inputTab) {
            onToggleScope?()
            return
        }
        if kb.matches(keyData, TUIKeybinding.selectUp) {
            selectedIndex = max(0, selectedIndex - 1)
            return
        }
        if kb.matches(keyData, TUIKeybinding.selectDown) {
            selectedIndex = min(filteredSessions.count - 1, selectedIndex + 1)
            return
        }
        if kb.matches(keyData, TUIKeybinding.selectPageUp) {
            selectedIndex = max(0, selectedIndex - maxVisible)
            return
        }
        if kb.matches(keyData, TUIKeybinding.selectPageDown) {
            selectedIndex = min(filteredSessions.count - 1, selectedIndex + maxVisible)
            return
        }
        if kb.matches(keyData, TUIKeybinding.selectConfirm) {
            if let selected = filteredSessions[safe: selectedIndex] {
                onSelect?(selected.path)
            }
            return
        }
        if kb.matches(keyData, TUIKeybinding.selectCancel) {
            onCancel?()
            return
        }

        searchInput.handleInput(keyData)
        filterSessions(searchInput.getValue())
    }

    private func filterSessions(_ query: String) {
        filteredSessions = fuzzyFilter(allSessions, query: query) { session in
            "\(session.id) \(session.name ?? "") \(session.allMessagesText) \(session.cwd)"
        }
        selectedIndex = min(selectedIndex, max(0, filteredSessions.count - 1))
    }
}

public final class SessionSelectorComponent: Container {
    private let sessionList: SessionList
    private let header: SessionSelectorHeader
    private var scope: SessionScope = .current
    private var currentSessions: [SessionInfo]?
    private var allSessions: [SessionInfo]?
    private let currentSessionsLoader: SessionsLoader
    private let allSessionsLoader: SessionsLoader
    private let onCancel: () -> Void
    private let requestRender: () -> Void

    public init(
        currentSessionsLoader: @escaping SessionsLoader,
        allSessionsLoader: @escaping SessionsLoader,
        onSelect: @escaping (String) -> Void,
        onCancel: @escaping () -> Void,
        onExit: @escaping () -> Void,
        requestRender: @escaping () -> Void
    ) {
        self.currentSessionsLoader = currentSessionsLoader
        self.allSessionsLoader = allSessionsLoader
        self.onCancel = onCancel
        self.requestRender = requestRender
        self.header = SessionSelectorHeader(scope: scope)
        self.sessionList = SessionList(sessions: [], showCwd: false)
        super.init()

        addChild(Spacer(1))
        addChild(header)
        addChild(Spacer(1))
        addChild(DynamicBorder())
        addChild(Spacer(1))

        sessionList.onSelect = onSelect
        sessionList.onCancel = onCancel
        sessionList.onExit = onExit
        sessionList.onToggleScope = { [weak self] in
            self?.toggleScope()
        }

        addChild(sessionList)
        addChild(Spacer(1))
        addChild(DynamicBorder())

        loadCurrentSessions()
    }

    private func loadCurrentSessions() {
        header.setLoading(true)
        requestRender()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let sessions = await currentSessionsLoader { [weak self] loaded, total in
                Task { @MainActor [weak self] in
                    self?.header.setProgress(loaded: loaded, total: total)
                    self?.requestRender()
                }
            }
            self.currentSessions = sessions
            self.header.setLoading(false)
            self.sessionList.setSessions(sessions, showCwd: false)
            self.requestRender()
        }
    }

    private func toggleScope() {
        if scope == .current {
            if allSessions == nil {
                header.setLoading(true)
                header.setScope(.all)
                sessionList.setSessions([], showCwd: true)
                requestRender()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let sessions = await allSessionsLoader { [weak self] loaded, total in
                        Task { @MainActor [weak self] in
                            self?.header.setProgress(loaded: loaded, total: total)
                            self?.requestRender()
                        }
                    }
                    self.allSessions = sessions
                    self.header.setLoading(false)
                    self.scope = .all
                    self.sessionList.setSessions(sessions, showCwd: true)
                    self.requestRender()
                    if (self.allSessions?.isEmpty ?? true) && (self.currentSessions?.isEmpty ?? true) {
                        self.onCancel()
                    }
                }
            } else {
                scope = .all
                sessionList.setSessions(allSessions ?? [], showCwd: true)
                header.setScope(scope)
            }
        } else {
            scope = .current
            sessionList.setSessions(currentSessions ?? [], showCwd: false)
            header.setScope(scope)
        }
    }

    public func getSessionList() -> Component {
        sessionList
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard index >= 0 && index < count else { return nil }
        return self[index]
    }
}
