import Foundation
import MiniTui
import PiSwiftAI
import PiSwiftCodingAgent

private typealias EnabledIds = [String]?

private func isEnabled(_ enabledIds: EnabledIds, _ id: String) -> Bool {
    enabledIds == nil || enabledIds?.contains(id) == true
}

private func toggle(_ enabledIds: EnabledIds, _ id: String) -> EnabledIds {
    guard var enabledIds else { return [id] }
    if let index = enabledIds.firstIndex(of: id) {
        enabledIds.remove(at: index)
    } else {
        enabledIds.append(id)
    }
    return enabledIds
}

private func enableAll(_ enabledIds: EnabledIds, _ allIds: [String], targetIds: [String]? = nil) -> EnabledIds {
    guard var enabledIds else { return nil }
    let targets = targetIds ?? allIds
    for id in targets where !enabledIds.contains(id) {
        enabledIds.append(id)
    }
    return enabledIds.count == allIds.count ? nil : enabledIds
}

private func clearAll(_ enabledIds: EnabledIds, _ allIds: [String], targetIds: [String]? = nil) -> EnabledIds {
    if enabledIds == nil {
        if let targetIds {
            return allIds.filter { !targetIds.contains($0) }
        }
        return []
    }
    let targets = Set(targetIds ?? enabledIds ?? [])
    return enabledIds?.filter { !targets.contains($0) }
}

private func move(_ enabledIds: EnabledIds, _ allIds: [String], _ id: String, delta: Int) -> EnabledIds {
    var list = enabledIds ?? allIds
    guard let index = list.firstIndex(of: id) else { return list }
    let newIndex = index + delta
    guard newIndex >= 0 && newIndex < list.count else { return list }
    list.swapAt(index, newIndex)
    return list
}

private func getSortedIds(_ enabledIds: EnabledIds, _ allIds: [String]) -> [String] {
    guard let enabledIds else { return allIds }
    let enabledSet = Set(enabledIds)
    return enabledIds + allIds.filter { !enabledSet.contains($0) }
}

private struct ModelItem {
    let fullId: String
    let model: Model
    let enabled: Bool
}

public struct ModelsConfig: Sendable {
    public var allModels: [Model]
    public var enabledModelIds: [String]
    public var hasEnabledModelsFilter: Bool

    public init(allModels: [Model], enabledModelIds: [String], hasEnabledModelsFilter: Bool) {
        self.allModels = allModels
        self.enabledModelIds = enabledModelIds
        self.hasEnabledModelsFilter = hasEnabledModelsFilter
    }
}

public struct ModelsCallbacks {
    public var onModelToggle: (String, Bool) -> Void
    public var onPersist: ([String]) -> Void
    public var onEnableAll: ([String]) -> Void
    public var onClearAll: () -> Void
    public var onToggleProvider: (String, [String], Bool) -> Void
    public var onCancel: () -> Void

    public init(
        onModelToggle: @escaping (String, Bool) -> Void,
        onPersist: @escaping ([String]) -> Void,
        onEnableAll: @escaping ([String]) -> Void,
        onClearAll: @escaping () -> Void,
        onToggleProvider: @escaping (String, [String], Bool) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onModelToggle = onModelToggle
        self.onPersist = onPersist
        self.onEnableAll = onEnableAll
        self.onClearAll = onClearAll
        self.onToggleProvider = onToggleProvider
        self.onCancel = onCancel
    }
}

@MainActor
public final class ScopedModelsSelectorComponent: Container, SystemCursorAware {
    private var modelsById: [String: Model] = [:]
    private var allIds: [String] = []
    private var enabledIds: EnabledIds = nil
    private var filteredItems: [ModelItem] = []
    private var selectedIndex = 0
    private let searchInput: Input
    private let listContainer: Container
    private let footerText: Text
    private let callbacks: ModelsCallbacks
    private let maxVisible = 15
    private var isDirty = false
    public var usesSystemCursor: Bool {
        get { searchInput.usesSystemCursor }
        set { searchInput.usesSystemCursor = newValue }
    }

    public init(config: ModelsConfig, callbacks: ModelsCallbacks) {
        self.callbacks = callbacks

        for model in config.allModels {
            let fullId = "\(model.provider)/\(model.id)"
            modelsById[fullId] = model
            allIds.append(fullId)
        }

        enabledIds = config.hasEnabledModelsFilter ? config.enabledModelIds : nil
        filteredItems = []

        searchInput = Input()
        listContainer = Container()
        footerText = Text("", paddingX: 0, paddingY: 0)

        super.init()

        addChild(DynamicBorder())
        addChild(Spacer(1))
        addChild(Text(theme.fg(.accent, theme.bold("Model Configuration")), paddingX: 0, paddingY: 0))
        addChild(Text(theme.fg(.muted, "Session-only. Ctrl+S to save to settings."), paddingX: 0, paddingY: 0))
        addChild(Spacer(1))
        addChild(searchInput)
        addChild(Spacer(1))
        addChild(listContainer)
        addChild(Spacer(1))
        addChild(footerText)
        addChild(DynamicBorder())

        refresh()
    }

    private func buildItems() -> [ModelItem] {
        getSortedIds(enabledIds, allIds).compactMap { id in
            guard let model = modelsById[id] else { return nil }
            return ModelItem(fullId: id, model: model, enabled: isEnabled(enabledIds, id))
        }
    }

    private func getFooterText() -> String {
        let enabledCount = enabledIds?.count ?? allIds.count
        let allEnabled = enabledIds == nil
        let countText = allEnabled ? "all enabled" : "\(enabledCount)/\(allIds.count) enabled"
        let parts = ["Enter toggle", "^A all", "^X clear", "^P provider", "Alt+Up/Down reorder", "^S save", countText]
        let hint = theme.fg(.dim, "  \(parts.joined(separator: " · "))")
        if isDirty {
            return hint + theme.fg(.warning, " (unsaved)")
        }
        return hint
    }

    private func refresh() {
        let query = searchInput.getValue()
        let items = buildItems()
        if query.isEmpty {
            filteredItems = items
        } else {
            filteredItems = fuzzyFilter(items, query: query) { "\($0.model.id) \($0.model.provider)" }
        }
        selectedIndex = min(selectedIndex, max(0, filteredItems.count - 1))
        updateList()
        footerText.setText(getFooterText())
    }

    private func updateList() {
        listContainer.clear()

        if filteredItems.isEmpty {
            listContainer.addChild(Text(theme.fg(.muted, "  No matching models"), paddingX: 0, paddingY: 0))
            return
        }

        let startIndex = max(0, min(selectedIndex - maxVisible / 2, filteredItems.count - maxVisible))
        let endIndex = min(startIndex + maxVisible, filteredItems.count)
        let allEnabled = enabledIds == nil

        for i in startIndex..<endIndex {
            let item = filteredItems[i]
            let isSelected = i == selectedIndex
            let prefix = isSelected ? theme.fg(.accent, "→ ") : "  "
            let modelText = isSelected ? theme.fg(.accent, item.model.id) : item.model.id
            let providerBadge = theme.fg(.muted, " [\(item.model.provider)]")
            let status = allEnabled ? "" : (item.enabled ? theme.fg(.success, " ✓") : theme.fg(.dim, " ✗"))
            listContainer.addChild(Text("\(prefix)\(modelText)\(providerBadge)\(status)", paddingX: 0, paddingY: 0))
        }

        if startIndex > 0 || endIndex < filteredItems.count {
            listContainer.addChild(Text(theme.fg(.muted, "  (\(selectedIndex + 1)/\(filteredItems.count))"), paddingX: 0, paddingY: 0))
        }
    }

    public override func handleInput(_ data: String) {
        let kb = getKeybindings()

        if kb.matches(data, TUIKeybinding.selectUp) {
            guard !filteredItems.isEmpty else { return }
            selectedIndex = selectedIndex == 0 ? filteredItems.count - 1 : selectedIndex - 1
            updateList()
            return
        }
        if kb.matches(data, TUIKeybinding.selectDown) {
            guard !filteredItems.isEmpty else { return }
            selectedIndex = selectedIndex == filteredItems.count - 1 ? 0 : selectedIndex + 1
            updateList()
            return
        }

        if matchesKey(data, Key.alt("up")) || matchesKey(data, Key.alt("down")) {
            guard let item = filteredItems[safe: selectedIndex], isEnabled(enabledIds, item.fullId) else { return }
            let delta = matchesKey(data, Key.alt("up")) ? -1 : 1
            let enabledList = enabledIds ?? allIds
            guard let currentIndex = enabledList.firstIndex(of: item.fullId) else { return }
            let newIndex = currentIndex + delta
            guard newIndex >= 0 && newIndex < enabledList.count else { return }
            enabledIds = move(enabledIds, allIds, item.fullId, delta: delta)
            isDirty = true
            selectedIndex += delta
            refresh()
            return
        }

        if kb.matches(data, TUIKeybinding.selectConfirm) {
            guard let item = filteredItems[safe: selectedIndex] else { return }
            let wasAllEnabled = enabledIds == nil
            enabledIds = toggle(enabledIds, item.fullId)
            isDirty = true
            if wasAllEnabled {
                callbacks.onClearAll()
            }
            callbacks.onModelToggle(item.fullId, isEnabled(enabledIds, item.fullId))
            refresh()
            return
        }

        if matchesKey(data, Key.ctrl("a")) {
            let targetIds = searchInput.getValue().isEmpty ? nil : filteredItems.map { $0.fullId }
            enabledIds = enableAll(enabledIds, allIds, targetIds: targetIds)
            isDirty = true
            callbacks.onEnableAll(targetIds ?? allIds)
            refresh()
            return
        }

        if matchesKey(data, Key.ctrl("x")) {
            let targetIds = searchInput.getValue().isEmpty ? nil : filteredItems.map { $0.fullId }
            enabledIds = clearAll(enabledIds, allIds, targetIds: targetIds)
            isDirty = true
            callbacks.onClearAll()
            refresh()
            return
        }

        if matchesKey(data, Key.ctrl("p")) {
            guard let item = filteredItems[safe: selectedIndex] else { return }
            let provider = item.model.provider
            let providerIds = allIds.filter { modelsById[$0]?.provider == provider }
            let allEnabled = providerIds.allSatisfy { isEnabled(enabledIds, $0) }
            enabledIds = allEnabled
                ? clearAll(enabledIds, allIds, targetIds: providerIds)
                : enableAll(enabledIds, allIds, targetIds: providerIds)
            isDirty = true
            callbacks.onToggleProvider(provider, providerIds, !allEnabled)
            refresh()
            return
        }

        if matchesKey(data, Key.ctrl("s")) {
            callbacks.onPersist(enabledIds ?? allIds)
            isDirty = false
            footerText.setText(getFooterText())
            return
        }

        if matchesKey(data, Key.ctrl("c")) {
            if !searchInput.getValue().isEmpty {
                searchInput.setValue("")
                refresh()
            } else {
                callbacks.onCancel()
            }
            return
        }

        if matchesKey(data, Key.escape) {
            callbacks.onCancel()
            return
        }

        searchInput.handleInput(data)
        refresh()
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
