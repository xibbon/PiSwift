import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftCodingAgent

private struct ModelItem {
    let provider: String
    let id: String
    let model: Model
}

private struct ScopedModelItem {
    let model: Model
    let thinkingLevel: String
}

@MainActor
public final class ModelSelectorComponent: Container, SystemCursorAware {
    private let searchInput: Input
    private let listContainer: Container
    private var allModels: [ModelItem] = []
    private var filteredModels: [ModelItem] = []
    private var selectedIndex = 0
    private let currentModel: Model?
    private let settingsManager: SettingsManager
    private let modelRegistry: ModelRegistry
    private let onSelectCallback: (Model) -> Void
    private let onCancelCallback: () -> Void
    private var errorMessage: String?
    private let tui: TUI
    private let scopedModels: [ScopedModelItem]
    private let initialSearchInput: String?
    public var usesSystemCursor: Bool {
        get { searchInput.usesSystemCursor }
        set { searchInput.usesSystemCursor = newValue }
    }

    public init(
        tui: TUI,
        currentModel: Model?,
        settingsManager: SettingsManager,
        modelRegistry: ModelRegistry,
        scopedModels: [ScopedModel],
        onSelect: @escaping (Model) -> Void,
        onCancel: @escaping () -> Void,
        initialSearchInput: String? = nil
    ) {
        self.tui = tui
        self.currentModel = currentModel
        self.settingsManager = settingsManager
        self.modelRegistry = modelRegistry
        self.scopedModels = scopedModels.map { ScopedModelItem(model: $0.model, thinkingLevel: ($0.thinkingLevel ?? .off).rawValue) }
        self.onSelectCallback = onSelect
        self.onCancelCallback = onCancel
        self.initialSearchInput = initialSearchInput

        self.searchInput = Input()
        if let initialSearchInput, !initialSearchInput.isEmpty {
            self.searchInput.setValue(initialSearchInput)
        }
        self.listContainer = Container()

        super.init()

        addChild(DynamicBorder())
        addChild(Spacer(1))

        let hintText = scopedModels.isEmpty
            ? "Only showing models with configured API keys (see README for details)"
            : "Showing models from --models scope"
        addChild(Text(theme.fg(.warning, hintText), paddingX: 0, paddingY: 0))
        addChild(Spacer(1))

        searchInput.onSubmit = { [weak self] _ in
            guard let self else { return }
            if let selected = self.filteredModels[safe: self.selectedIndex] {
                self.handleSelect(selected.model)
            }
        }
        addChild(searchInput)
        addChild(Spacer(1))

        addChild(listContainer)
        addChild(Spacer(1))
        addChild(DynamicBorder())

        loadModels()
    }

    private func loadModels() {
        Task { @MainActor in
            var items: [ModelItem] = []

            if !scopedModels.isEmpty {
                items = scopedModels.map { scoped in
                    ModelItem(provider: scoped.model.provider, id: scoped.model.id, model: scoped.model)
                }
            } else {
                modelRegistry.refresh()
                errorMessage = modelRegistry.getError()
                let available = await modelRegistry.getAvailable()
                items = available.map { model in
                    ModelItem(provider: model.provider, id: model.id, model: model)
                }
            }

            items.sort { lhs, rhs in
                let lhsCurrent = modelsAreEqual(currentModel, lhs.model)
                let rhsCurrent = modelsAreEqual(currentModel, rhs.model)
                if lhsCurrent != rhsCurrent {
                    return lhsCurrent
                }
                return lhs.provider.localizedCaseInsensitiveCompare(rhs.provider) == .orderedAscending
            }

            allModels = items
            filteredModels = items
            selectedIndex = min(selectedIndex, max(0, items.count - 1))
            if let initialSearchInput, !initialSearchInput.isEmpty {
                filterModels(initialSearchInput)
            } else {
                updateList()
            }
            tui.requestRender()
        }
    }

    private func filterModels(_ query: String) {
        filteredModels = fuzzyFilter(allModels, query) { "\($0.id) \($0.provider)" }
        selectedIndex = min(selectedIndex, max(0, filteredModels.count - 1))
        updateList()
    }

    private func updateList() {
        listContainer.clear()

        let maxVisible = 10
        let startIndex = max(0, min(selectedIndex - maxVisible / 2, filteredModels.count - maxVisible))
        let endIndex = min(startIndex + maxVisible, filteredModels.count)

        for i in startIndex..<endIndex {
            let item = filteredModels[i]
            let isSelected = i == selectedIndex
            let isCurrent = modelsAreEqual(currentModel, item.model)

            let modelText = item.id
            let providerBadge = theme.fg(.muted, "[\(item.provider)]")
            let checkmark = isCurrent ? theme.fg(.success, " ✓") : ""

            let line: String
            if isSelected {
                let prefix = theme.fg(.accent, "→ ")
                line = "\(prefix)\(theme.fg(.accent, modelText)) \(providerBadge)\(checkmark)"
            } else {
                line = "  \(modelText) \(providerBadge)\(checkmark)"
            }

            listContainer.addChild(Text(line, paddingX: 0, paddingY: 0))
        }

        if startIndex > 0 || endIndex < filteredModels.count {
            let scrollInfo = theme.fg(.muted, "  (\(selectedIndex + 1)/\(filteredModels.count))")
            listContainer.addChild(Text(scrollInfo, paddingX: 0, paddingY: 0))
        }

        if let errorMessage {
            for line in errorMessage.split(separator: "\n", omittingEmptySubsequences: false) {
                listContainer.addChild(Text(theme.fg(.error, String(line)), paddingX: 0, paddingY: 0))
            }
        } else if filteredModels.isEmpty {
            listContainer.addChild(Text(theme.fg(.muted, "  No matching models"), paddingX: 0, paddingY: 0))
        }
    }

    public override func handleInput(_ keyData: String) {
        let kb = getKeybindings()
        if kb.matches(keyData, TUIKeybinding.selectUp) {
            guard !filteredModels.isEmpty else { return }
            selectedIndex = selectedIndex == 0 ? filteredModels.count - 1 : selectedIndex - 1
            updateList()
            return
        }
        if kb.matches(keyData, TUIKeybinding.selectDown) {
            guard !filteredModels.isEmpty else { return }
            selectedIndex = selectedIndex == filteredModels.count - 1 ? 0 : selectedIndex + 1
            updateList()
            return
        }
        if kb.matches(keyData, TUIKeybinding.selectConfirm) {
            if let selected = filteredModels[safe: selectedIndex] {
                handleSelect(selected.model)
            }
            return
        }
        if kb.matches(keyData, TUIKeybinding.selectCancel) {
            onCancelCallback()
            return
        }

        searchInput.handleInput(keyData)
        filterModels(searchInput.getValue())
    }

    private func handleSelect(_ model: Model) {
        settingsManager.setDefaultModelAndProvider(model.provider, model.id)
        onSelectCallback(model)
    }

    public func getSearchInput() -> Input {
        searchInput
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard index >= 0 && index < count else { return nil }
        return self[index]
    }
}
