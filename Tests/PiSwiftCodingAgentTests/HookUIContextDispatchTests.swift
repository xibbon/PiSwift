import Testing
@testable import PiSwiftCodingAgent

@MainActor
private protocol DispatchTestUIContext: HookUIContext {}

private extension DispatchTestUIContext {
    func select(_ title: String, _ options: [String]) async -> String? { nil }
    func confirm(_ title: String, _ message: String) async -> Bool { false }
    func input(_ title: String, _ placeholder: String?) async -> String? { nil }
    func notify(_ message: String, _ type: HookNotificationType?) {}
    func setStatus(_ key: String, _ text: String?) {}
    func setWorkingMessage(_ message: String?) {}
    func setWidget(_ key: String, _ content: HookWidgetContent?) {}
    func setFooter(_ factory: HookFooterFactory?) {}
    func setTitle(_ title: String) {}
    func custom(_ factory: @escaping HookCustomFactory, options: HookCustomOptions?) async -> HookCustomResult? { nil }
    func pasteToEditor(_ text: String) {}
    func setEditorText(_ text: String) {}
    func getEditorText() -> String { "" }
    func editor(_ title: String, _ prefill: String?) async -> String? { nil }
    func setEditorComponent(_ factory: HookEditorComponentFactory?) {}
    func getAllThemes() -> [HookThemeInfo] { [] }
    func getTheme(_ name: String) -> Theme? { nil }
    func setTheme(_ theme: HookThemeInput) -> HookThemeResult { HookThemeResult(success: false) }
    func getToolsExpanded() -> Bool { false }
    func setToolsExpanded(_ expanded: Bool) {}
    var theme: Theme { Theme.fallback() }
}

private final class DispatchRecorderUIContext: DispatchTestUIContext {
    var calls: [String] = []
    var visible: Bool?
    var indicator: WorkingIndicatorOptions?
    var thinkingLabel: String?
    var autocompleteFactory: HookAutocompleteProviderFactory?

    func setWorkingVisible(_ visible: Bool) {
        calls.append("visible")
        self.visible = visible
    }

    func setWorkingIndicator(_ options: WorkingIndicatorOptions?) {
        calls.append("indicator")
        indicator = options
    }

    func setHiddenThinkingLabel(_ label: String?) {
        calls.append("thinking")
        thinkingLabel = label
    }

    func addAutocompleteProvider(_ factory: @escaping HookAutocompleteProviderFactory) {
        calls.append("autocomplete")
        autocompleteFactory = factory
    }
}

private final class DefaultDispatchUIContext: DispatchTestUIContext {}

@MainActor
@Suite struct HookUIContextDispatchTests {
    private func checkDispatch(_ context: any HookUIContext, recorder: DispatchRecorderUIContext) {
        context.setWorkingVisible(false)
        context.setWorkingIndicator(WorkingIndicatorOptions(frames: ["a", "b"], intervalMs: 125))
        context.setHiddenThinkingLabel("Wait")
        context.addAutocompleteProvider { value in "wrapped:\(value)" }

        #expect(recorder.calls == ["visible", "indicator", "thinking", "autocomplete"])
        #expect(recorder.visible == false)
        #expect(recorder.indicator?.frames == ["a", "b"])
        #expect(recorder.indicator?.intervalMs == 125)
        #expect(recorder.thinkingLabel == "Wait")
        #expect(recorder.autocompleteFactory?("base") as? String == "wrapped:base")

        context.setWorkingVisible(true)
        context.setWorkingIndicator(nil)
        context.setHiddenThinkingLabel(nil)

        #expect(recorder.visible == true)
        #expect(recorder.indicator == nil)
        #expect(recorder.thinkingLabel == nil)
        #expect(recorder.calls == ["visible", "indicator", "thinking", "autocomplete", "visible", "indicator", "thinking"])
    }

    @Test func controlsDispatchThroughExistential() {
        let recorder = DispatchRecorderUIContext()
        let context: any HookUIContext = recorder
        checkDispatch(context, recorder: recorder)
    }

    @Test func promptContextForwardsControls() {
        let recorder = DispatchRecorderUIContext()
        let runner = HookRunner([], "/tmp", SessionManager.inMemory(), ModelRegistry(AuthStorage(":memory:")))
        let context: any HookUIContext = PromptHookUIContext(base: recorder, runner: runner)
        checkDispatch(context, recorder: recorder)
    }

    @Test func omittedControlsUseDefaultNoOps() {
        let context: any HookUIContext = DefaultDispatchUIContext()
        context.setWorkingVisible(false)
        context.setWorkingIndicator(WorkingIndicatorOptions(frames: ["a"], intervalMs: 125))
        context.setWorkingIndicator(nil)
        context.setHiddenThinkingLabel("Wait")
        context.setHiddenThinkingLabel(nil)
        context.addAutocompleteProvider { value in
            Issue.record("The default method must not call the factory.")
            return value
        }
        #expect(context.getEditorText().isEmpty)
    }
}
