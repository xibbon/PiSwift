import Foundation
import MiniTui
import PiSwiftCodingAgent

public final class CustomEditor: Component, SystemCursorAware, EditorComponent {
    private let editor: Editor
    private let keybindings: KeybindingsManager
    public var actionHandlers: [AppAction: () -> Void] = [:]

    public var usesSystemCursor: Bool {
        get { editor.usesSystemCursor }
        set { editor.usesSystemCursor = newValue }
    }

    public var onEscape: (() -> Void)?
    public var onCtrlD: (() -> Void)?
    public var onPasteImage: (() -> Void)?
    public var onHookShortcut: ((String) -> Bool)?

    public var onSubmit: ((String) -> Void)? {
        get { editor.onSubmit }
        set { editor.onSubmit = newValue }
    }

    public var onChange: ((String) -> Void)? {
        get { editor.onChange }
        set { editor.onChange = newValue }
    }

    public var disableSubmit: Bool {
        get { editor.disableSubmit }
        set { editor.disableSubmit = newValue }
    }

    public var borderColor: @Sendable (String) -> String {
        get { editor.borderColor }
        set { editor.borderColor = newValue }
    }

    public init(theme: EditorTheme, keybindings: KeybindingsManager, options: EditorOptions = EditorOptions()) {
        self.editor = Editor(theme: theme, options: options)
        self.keybindings = keybindings
    }

    public func onAction(_ action: AppAction, handler: @escaping () -> Void) {
        actionHandlers[action] = handler
    }

    public func setText(_ text: String) {
        editor.setText(text)
    }

    public func getText() -> String {
        editor.getText()
    }

    public func getExpandedText() -> String {
        editor.getExpandedText()
    }

    public func insertTextAtCursor(_ text: String) {
        editor.insertTextAtCursor(text)
    }

    public func addToHistory(_ text: String) {
        editor.addToHistory(text)
    }

    public func setAutocompleteProvider(_ provider: AutocompleteProvider) {
        editor.setAutocompleteProvider(provider)
    }

    public func setPaddingX(_ padding: Int) {
        editor.setPaddingX(padding)
    }

    public func getPaddingX() -> Int {
        editor.getPaddingX()
    }

    public func setAutocompleteMaxVisible(_ maxVisible: Int) {
        editor.setAutocompleteMaxVisible(maxVisible)
    }

    public func isShowingAutocomplete() -> Bool {
        editor.isShowingAutocomplete()
    }

    public func invalidate() {
        editor.invalidate()
    }

    public func render(width: Int) -> [String] {
        editor.render(width: width)
    }

    public func handleInput(_ data: String) {
        if onHookShortcut?(data) == true {
            return
        }

        if keybindings.matches(data, .pasteImage) {
            onPasteImage?()
            return
        }

        if keybindings.matches(data, .interrupt) {
            if !editor.isShowingAutocomplete() {
                let handler = onEscape ?? actionHandlers[.interrupt]
                handler?()
                return
            }
            editor.handleInput(data)
            return
        }

        if keybindings.matches(data, .exit) {
            if editor.getText().isEmpty {
                let handler = onCtrlD ?? actionHandlers[.exit]
                handler?()
                return
            }
        }

        for (action, handler) in actionHandlers where action != .interrupt && action != .exit {
            if keybindings.matches(data, action) {
                handler()
                return
            }
        }

        editor.handleInput(data)
    }
}
