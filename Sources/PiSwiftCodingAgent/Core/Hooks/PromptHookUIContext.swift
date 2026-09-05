import Foundation

/// Keep one lifecycle pair around nested UI requests. All UI state is on MainActor.
final class PromptHookUIContext: HookUIContext {
    private let base: any HookUIContext
    private weak var runner: HookRunner?
    private var depth = 0
    private var activePrompt: (UIPromptKind, String?)?
    private var events: Task<Void, Never>?

    nonisolated init(base: any HookUIContext, runner: HookRunner) {
        self.base = base
        self.runner = runner
    }

    private func emit(_ event: any HookEvent) {
        let previous = events
        let runner = runner
        events = Task {
            await previous?.value
            _ = await runner?.emit(event)
        }
    }

    private func prompt<T>(_ kind: UIPromptKind, _ title: String?, _ operation: () async -> T) async -> T {
        let outermost = depth == 0
        depth += 1
        if outermost {
            activePrompt = (kind, title)
            emit(UIPromptStartEvent(kind: kind, title: title))
        }
        defer {
            depth -= 1
            if depth == 0, let (kind, title) = activePrompt {
                activePrompt = nil
                emit(UIPromptEndEvent(kind: kind, title: title))
            }
        }
        return await operation()
    }

    func select(_ title: String, _ options: [String]) async -> String? {
        await prompt(.select, title) { await base.select(title, options) }
    }
    func confirm(_ title: String, _ message: String) async -> Bool {
        await prompt(.confirm, title) { await base.confirm(title, message) }
    }
    func input(_ title: String, _ placeholder: String?) async -> String? {
        await prompt(.input, title) { await base.input(title, placeholder) }
    }
    func editor(_ title: String, _ prefill: String?) async -> String? {
        await prompt(.editor, title) { await base.editor(title, prefill) }
    }
    func custom(_ factory: @escaping HookCustomFactory, options: HookCustomOptions?) async -> HookCustomResult? {
        await prompt(.custom, nil) { await base.custom(factory, options: options) }
    }
    func notify(_ message: String, _ type: HookNotificationType?) { base.notify(message, type) }
    func setStatus(_ key: String, _ text: String?) { base.setStatus(key, text) }
    func setWorkingMessage(_ message: String?) { base.setWorkingMessage(message) }
    func setWidget(_ key: String, _ content: HookWidgetContent?) { base.setWidget(key, content) }
    func setFooter(_ factory: HookFooterFactory?) { base.setFooter(factory) }
    func setTitle(_ title: String) { base.setTitle(title) }
    func pasteToEditor(_ text: String) { base.pasteToEditor(text) }
    func setEditorText(_ text: String) { base.setEditorText(text) }
    func getEditorText() -> String { base.getEditorText() }
    func setEditorComponent(_ factory: HookEditorComponentFactory?) { base.setEditorComponent(factory) }
    func getAllThemes() -> [HookThemeInfo] { base.getAllThemes() }
    func getTheme(_ name: String) -> Theme? { base.getTheme(name) }
    func setTheme(_ theme: HookThemeInput) -> HookThemeResult { base.setTheme(theme) }
    func getToolsExpanded() -> Bool { base.getToolsExpanded() }
    func setToolsExpanded(_ expanded: Bool) { base.setToolsExpanded(expanded) }
    var theme: Theme { base.theme }
}
