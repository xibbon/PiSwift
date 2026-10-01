import Foundation

/// Data for a host's `/mcp` manager. The host controls rendering and selection.
public struct McpMenuItem: Sendable, Equatable {
    public var value: String
    public var label: String
    public var detail: String?

    public init(value: String, label: String, detail: String? = nil) {
        self.value = value; self.label = label; self.detail = detail
    }
}

public struct McpMenu: Sendable, Equatable {
    public var title: String
    public var details: String?
    public var error: String?
    public var items: [McpMenuItem]
    public var empty: String?
    public var selected: String?
    public var confirmLabel: String
    public var cancelLabel: String

    public init(title: String, details: String? = nil, error: String? = nil, items: [McpMenuItem],
                empty: String? = nil, selected: String? = nil,
                confirmLabel: String, cancelLabel: String) {
        self.title = title; self.details = details; self.error = error; self.items = items
        self.empty = empty; self.selected = selected
        self.confirmLabel = confirmLabel; self.cancelLabel = cancelLabel
    }
}

/// A mobile or TUI host implements this to render the manager and OAuth paste prompt.
@MainActor public protocol McpUi: Sendable {
    func menu(_ menu: McpMenu) async -> String?
    func status(title: String, message: String)
    func redirectURL(title: String, authorizationURL: URL) async -> URL?
}
