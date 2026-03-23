import Foundation
import MiniTui
import PiSwiftCodingAgent

enum ResourceType: String {
    case extensions
    case skills
    case prompts
    case themes

    var label: String {
        switch self {
        case .extensions:
            return "Extensions"
        case .skills:
            return "Skills"
        case .prompts:
            return "Prompts"
        case .themes:
            return "Themes"
        }
    }
}

private func stripPatternPrefix(_ pattern: String) -> String {
    if pattern.hasPrefix("!") || pattern.hasPrefix("+") || pattern.hasPrefix("-") {
        return String(pattern.dropFirst())
    }
    return pattern
}

func updateResourcePatterns(current: [String], pattern: String, enabled: Bool) -> [String] {
    let updated = current.filter { stripPatternPrefix($0) != pattern }
    let entry = (enabled ? "+" : "-") + pattern
    return updated + [entry]
}

func updatePackageSources(
    packages: [PackageSource],
    source: String,
    resourceType: ResourceType,
    pattern: String,
    enabled: Bool
) -> [PackageSource] {
    var updatedPackages = packages
    guard let index = updatedPackages.firstIndex(where: { $0.source == source }) else { return updatedPackages }

    let sourceValue = updatedPackages[index].source
    var filterSource: PackageFilterSource
    switch updatedPackages[index] {
    case .simple:
        filterSource = PackageFilterSource(source: sourceValue)
    case .filtered(let value):
        filterSource = value
    }

    let current: [String]
    switch resourceType {
    case .extensions:
        current = filterSource.extensions ?? []
    case .skills:
        current = filterSource.skills ?? []
    case .prompts:
        current = filterSource.prompts ?? []
    case .themes:
        current = filterSource.themes ?? []
    }

    let updated = updateResourcePatterns(current: current, pattern: pattern, enabled: enabled)

    switch resourceType {
    case .extensions:
        filterSource.extensions = updated.isEmpty ? nil : updated
    case .skills:
        filterSource.skills = updated.isEmpty ? nil : updated
    case .prompts:
        filterSource.prompts = updated.isEmpty ? nil : updated
    case .themes:
        filterSource.themes = updated.isEmpty ? nil : updated
    }

    let hasFilters = filterSource.extensions != nil
        || filterSource.skills != nil
        || filterSource.prompts != nil
        || filterSource.themes != nil

    updatedPackages[index] = hasFilters ? .filtered(filterSource) : .simple(sourceValue)
    return updatedPackages
}

private final class ResourceItem {
    let id: String
    let path: String
    var enabled: Bool
    let metadata: PathMetadata
    let resourceType: ResourceType
    let displayName: String
    let groupKey: String
    let subgroupKey: String

    init(
        path: String,
        enabled: Bool,
        metadata: PathMetadata,
        resourceType: ResourceType,
        displayName: String,
        groupKey: String,
        subgroupKey: String
    ) {
        self.path = path
        self.enabled = enabled
        self.metadata = metadata
        self.resourceType = resourceType
        self.displayName = displayName
        self.groupKey = groupKey
        self.subgroupKey = subgroupKey
        self.id = "\(resourceType.rawValue)|\(path)"
    }
}

private final class ResourceSubgroup {
    let key: String
    let type: ResourceType
    let label: String
    var items: [ResourceItem]

    init(key: String, type: ResourceType, label: String, items: [ResourceItem] = []) {
        self.key = key
        self.type = type
        self.label = label
        self.items = items
    }
}

private final class ResourceGroup {
    let key: String
    let label: String
    let scope: String
    let origin: String
    let source: String
    var subgroups: [ResourceSubgroup]

    init(
        key: String,
        label: String,
        scope: String,
        origin: String,
        source: String,
        subgroups: [ResourceSubgroup] = []
    ) {
        self.key = key
        self.label = label
        self.scope = scope
        self.origin = origin
        self.source = source
        self.subgroups = subgroups
    }
}

private enum FlatEntry {
    case group(ResourceGroup)
    case subgroup(ResourceSubgroup)
    case item(ResourceItem)

    var isItem: Bool {
        if case .item = self { return true }
        return false
    }
}

private func getGroupLabel(_ metadata: PathMetadata) -> String {
    if metadata.origin == "package" {
        return "\(metadata.source) (\(metadata.scope))"
    }
    if metadata.source == "auto" {
        return metadata.scope == "user" ? "User (~/.pi/agent/)" : "Project (.pi/)"
    }
    return metadata.scope == "user" ? "User settings" : "Project settings"
}

private func buildGroups(_ resolved: ResolvedPaths) -> [ResourceGroup] {
    var groupMap: [String: ResourceGroup] = [:]

    func addToGroup(_ resources: [ResolvedResource], resourceType: ResourceType) {
        for resource in resources {
            let metadata = resource.metadata
            let groupKey = "\(metadata.origin):\(metadata.scope):\(metadata.source)"
            let group = groupMap[groupKey] ?? ResourceGroup(
                key: groupKey,
                label: getGroupLabel(metadata),
                scope: metadata.scope,
                origin: metadata.origin,
                source: metadata.source
            )

            let subgroupKey = "\(groupKey):\(resourceType.rawValue)"
            let subgroup = group.subgroups.first { $0.type == resourceType } ?? ResourceSubgroup(
                key: subgroupKey,
                type: resourceType,
                label: resourceType.label
            )

            let fileName = URL(fileURLWithPath: resource.path).lastPathComponent
            let parentFolder = URL(fileURLWithPath: resource.path).deletingLastPathComponent().lastPathComponent
            let displayName: String
            if resourceType == .extensions, parentFolder != "extensions" {
                displayName = "\(parentFolder)/\(fileName)"
            } else if resourceType == .skills, fileName == "SKILL.md" {
                displayName = parentFolder
            } else {
                displayName = fileName
            }

            let item = ResourceItem(
                path: resource.path,
                enabled: resource.enabled,
                metadata: metadata,
                resourceType: resourceType,
                displayName: displayName,
                groupKey: groupKey,
                subgroupKey: subgroupKey
            )
            subgroup.items.append(item)

            if let index = group.subgroups.firstIndex(where: { $0.type == resourceType }) {
                group.subgroups[index] = subgroup
            } else {
                group.subgroups.append(subgroup)
            }
            groupMap[groupKey] = group
        }
    }

    addToGroup(resolved.extensions, resourceType: .extensions)
    addToGroup(resolved.skills, resourceType: .skills)
    addToGroup(resolved.prompts, resourceType: .prompts)
    addToGroup(resolved.themes, resourceType: .themes)

    var groups = Array(groupMap.values)
    groups.sort { lhs, rhs in
        if lhs.origin != rhs.origin {
            return lhs.origin == "package"
        }
        if lhs.scope != rhs.scope {
            return lhs.scope == "user"
        }
        return lhs.source.localizedCompare(rhs.source) == .orderedAscending
    }

    let typeOrder: [ResourceType: Int] = [
        .extensions: 0,
        .skills: 1,
        .prompts: 2,
        .themes: 3,
    ]

    for group in groups {
        group.subgroups.sort { (typeOrder[$0.type] ?? 0) < (typeOrder[$1.type] ?? 0) }
        for subgroup in group.subgroups {
            subgroup.items.sort { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
        }
    }

    return groups
}

private final class ConfigSelectorHeader: Component {
    func invalidate() {}

    func render(width: Int) -> [String] {
        let title = theme.bold("Resource Configuration")
        let hint = theme.fg(.muted, "space toggle - esc close")
        let spacing = max(1, width - visibleWidth(title) - visibleWidth(hint))
        return [
            truncateToWidth("\(title)\(String(repeating: " ", count: spacing))\(hint)", maxWidth: width, ellipsis: ""),
            theme.fg(.muted, "Type to filter resources"),
        ]
    }
}

private func relativePath(from baseDir: String, to fullPath: String) -> String {
    let base = URL(fileURLWithPath: baseDir).standardized.path
    let target = URL(fileURLWithPath: fullPath).standardized.path
    if target == base { return "" }
    let prefix = base.hasSuffix("/") ? base : "\(base)/"
    if target.hasPrefix(prefix) {
        return String(target.dropFirst(prefix.count))
    }

    let baseComponents = URL(fileURLWithPath: base).standardized.pathComponents
    let targetComponents = URL(fileURLWithPath: target).standardized.pathComponents
    var idx = 0
    let count = min(baseComponents.count, targetComponents.count)
    while idx < count, baseComponents[idx] == targetComponents[idx] {
        idx += 1
    }
    let up = Array(repeating: "..", count: max(0, baseComponents.count - idx))
    let rest = targetComponents[idx...]
    return (up + rest).joined(separator: "/")
}

private final class ResourceList: Component, SystemCursorAware {
    private var groups: [ResourceGroup]
    private var flatItems: [FlatEntry] = []
    private var filteredItems: [FlatEntry] = []
    private var selectedIndex = 0
    private let searchInput: Input
    private let maxVisible = 15
    private let settingsManager: SettingsManager
    private let cwd: String
    private let agentDir: String

    var onCancel: (() -> Void)?
    var onExit: (() -> Void)?
    var onToggle: ((ResourceItem, Bool) -> Void)?

    var usesSystemCursor: Bool {
        get { searchInput.usesSystemCursor }
        set { searchInput.usesSystemCursor = newValue }
    }

    init(groups: [ResourceGroup], settingsManager: SettingsManager, cwd: String, agentDir: String) {
        self.groups = groups
        self.settingsManager = settingsManager
        self.cwd = cwd
        self.agentDir = agentDir
        self.searchInput = Input()
        buildFlatList()
        self.filteredItems = flatItems
    }

    private func buildFlatList() {
        flatItems = []
        for group in groups {
            flatItems.append(.group(group))
            for subgroup in group.subgroups {
                flatItems.append(.subgroup(subgroup))
                for item in subgroup.items {
                    flatItems.append(.item(item))
                }
            }
        }
        selectFirstItem()
    }

    private func findNextItem(fromIndex: Int, direction: Int) -> Int {
        var idx = fromIndex + direction
        while idx >= 0, idx < filteredItems.count {
            if filteredItems[idx].isItem {
                return idx
            }
            idx += direction
        }
        return fromIndex
    }

    private func filterItems(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            filteredItems = flatItems
            selectFirstItem()
            return
        }

        let lowerQuery = trimmed.lowercased()
        var matchingItemIds = Set<String>()
        var matchingGroupKeys = Set<String>()
        var matchingSubgroupKeys = Set<String>()

        for entry in flatItems {
            guard case .item(let item) = entry else { continue }
            if item.displayName.lowercased().contains(lowerQuery)
                || item.resourceType.rawValue.lowercased().contains(lowerQuery)
                || item.path.lowercased().contains(lowerQuery) {
                matchingItemIds.insert(item.id)
                matchingGroupKeys.insert(item.groupKey)
                matchingSubgroupKeys.insert(item.subgroupKey)
            }
        }

        filteredItems = flatItems.filter { entry in
            switch entry {
            case .group(let group):
                return matchingGroupKeys.contains(group.key)
            case .subgroup(let subgroup):
                return matchingSubgroupKeys.contains(subgroup.key)
            case .item(let item):
                return matchingItemIds.contains(item.id)
            }
        }

        selectFirstItem()
    }

    private func selectFirstItem() {
        if let idx = filteredItems.firstIndex(where: { $0.isItem }) {
            selectedIndex = idx
        } else {
            selectedIndex = 0
        }
    }

    func invalidate() {
        searchInput.invalidate()
    }

    func render(width: Int) -> [String] {
        var lines: [String] = []
        lines.append(contentsOf: searchInput.render(width: width))
        lines.append("")

        if filteredItems.isEmpty {
            lines.append(theme.fg(.muted, "  No resources found"))
            return lines
        }

        let startIndex = max(0, min(selectedIndex - maxVisible / 2, filteredItems.count - maxVisible))
        let endIndex = min(startIndex + maxVisible, filteredItems.count)

        for idx in startIndex..<endIndex {
            let entry = filteredItems[idx]
            let isSelected = idx == selectedIndex
            switch entry {
            case .group(let group):
                let groupLine = theme.fg(.accent, theme.bold(group.label))
                lines.append(truncateToWidth("  \(groupLine)", maxWidth: width, ellipsis: ""))
            case .subgroup(let subgroup):
                let subgroupLine = theme.fg(.muted, subgroup.label)
                lines.append(truncateToWidth("    \(subgroupLine)", maxWidth: width, ellipsis: ""))
            case .item(let item):
                let cursor = isSelected ? "> " : "  "
                let checkbox = item.enabled ? theme.fg(.success, "[x]") : theme.fg(.dim, "[ ]")
                let name = isSelected ? theme.bold(item.displayName) : item.displayName
                lines.append(truncateToWidth("\(cursor)    \(checkbox) \(name)", maxWidth: width, ellipsis: "..."))
            }
        }

        if startIndex > 0 || endIndex < filteredItems.count {
            lines.append(theme.fg(.dim, "  (\(selectedIndex + 1)/\(filteredItems.count))"))
        }

        return lines
    }

    func handleInput(_ data: String) {
        let kb = getKeybindings()

        if matchesKey(data, Key.ctrl("c")) {
            onExit?()
            return
        }
        if kb.matches(data, TUIKeybinding.selectUp) {
            selectedIndex = findNextItem(fromIndex: selectedIndex, direction: -1)
            return
        }
        if kb.matches(data, TUIKeybinding.selectDown) {
            selectedIndex = findNextItem(fromIndex: selectedIndex, direction: 1)
            return
        }
        if kb.matches(data, TUIKeybinding.selectPageUp) {
            var target = max(0, selectedIndex - maxVisible)
            while target < filteredItems.count, !filteredItems[target].isItem {
                target += 1
            }
            if target < filteredItems.count {
                selectedIndex = target
            }
            return
        }
        if kb.matches(data, TUIKeybinding.selectPageDown) {
            var target = min(filteredItems.count - 1, selectedIndex + maxVisible)
            while target >= 0, !filteredItems[target].isItem {
                target -= 1
            }
            if target >= 0 {
                selectedIndex = target
            }
            return
        }
        if kb.matches(data, TUIKeybinding.selectCancel) {
            onCancel?()
            return
        }
        if data == " " || kb.matches(data, TUIKeybinding.selectConfirm) {
            guard selectedIndex >= 0, selectedIndex < filteredItems.count else { return }
            guard case .item(let item) = filteredItems[selectedIndex] else { return }
            let newEnabled = !item.enabled
            toggleResource(item, enabled: newEnabled)
            item.enabled = newEnabled
            onToggle?(item, newEnabled)
            return
        }

        searchInput.handleInput(data)
        filterItems(searchInput.getValue())
    }

    private func toggleResource(_ item: ResourceItem, enabled: Bool) {
        if item.metadata.origin == "top-level" {
            toggleTopLevelResource(item, enabled: enabled)
        } else {
            togglePackageResource(item, enabled: enabled)
        }
    }

    private func toggleTopLevelResource(_ item: ResourceItem, enabled: Bool) {
        let scope = item.metadata.scope == "project" ? "project" : "user"
        let settings = scope == "project"
            ? settingsManager.getProjectSettings()
            : settingsManager.getGlobalSettings()

        let current: [String]
        switch item.resourceType {
        case .extensions:
            current = settings.extensions ?? []
        case .skills:
            current = settings.skillPaths ?? []
        case .prompts:
            current = settings.prompts ?? []
        case .themes:
            current = settings.themes ?? []
        }

        let pattern = getResourcePattern(item)
        let updated = updateResourcePatterns(current: current, pattern: pattern, enabled: enabled)

        if scope == "project" {
            switch item.resourceType {
            case .extensions:
                settingsManager.setProjectExtensionPaths(updated)
            case .skills:
                settingsManager.setProjectSkillPaths(updated)
            case .prompts:
                settingsManager.setProjectPromptTemplatePaths(updated)
            case .themes:
                settingsManager.setProjectThemePaths(updated)
            }
        } else {
            switch item.resourceType {
            case .extensions:
                settingsManager.setExtensionPaths(updated)
            case .skills:
                settingsManager.setSkillPaths(updated)
            case .prompts:
                settingsManager.setPromptTemplatePaths(updated)
            case .themes:
                settingsManager.setThemePaths(updated)
            }
        }
    }

    private func togglePackageResource(_ item: ResourceItem, enabled: Bool) {
        let scope = item.metadata.scope == "project" ? "project" : "user"
        let settings = scope == "project"
            ? settingsManager.getProjectSettings()
            : settingsManager.getGlobalSettings()

        let packages = settings.packages ?? []
        let pattern = getPackageResourcePattern(item)
        let updatedPackages = updatePackageSources(
            packages: packages,
            source: item.metadata.source,
            resourceType: item.resourceType,
            pattern: pattern,
            enabled: enabled
        )

        if scope == "project" {
            settingsManager.setProjectPackages(updatedPackages)
        } else {
            settingsManager.setPackages(updatedPackages)
        }
    }

    private func getTopLevelBaseDir(_ scope: String) -> String {
        if scope == "project" {
            return URL(fileURLWithPath: cwd).appendingPathComponent(CONFIG_DIR_NAME).path
        }
        return agentDir
    }

    private func getResourcePattern(_ item: ResourceItem) -> String {
        let baseDir = getTopLevelBaseDir(item.metadata.scope)
        return relativePath(from: baseDir, to: item.path)
    }

    private func getPackageResourcePattern(_ item: ResourceItem) -> String {
        let baseDir = item.metadata.baseDir ?? URL(fileURLWithPath: item.path).deletingLastPathComponent().path
        return relativePath(from: baseDir, to: item.path)
    }
}

public final class ConfigSelectorComponent: Container {
    private let resourceList: ResourceList

    public init(
        resolvedPaths: ResolvedPaths,
        settingsManager: SettingsManager,
        cwd: String,
        agentDir: String,
        onClose: @escaping () -> Void,
        onExit: @escaping () -> Void,
        requestRender: @escaping () -> Void
    ) {
        let groups = buildGroups(resolvedPaths)
        self.resourceList = ResourceList(groups: groups, settingsManager: settingsManager, cwd: cwd, agentDir: agentDir)
        super.init()

        addChild(Spacer(1))
        addChild(DynamicBorder())
        addChild(Spacer(1))
        addChild(ConfigSelectorHeader())
        addChild(Spacer(1))

        resourceList.onCancel = onClose
        resourceList.onExit = onExit
        resourceList.onToggle = { _, _ in requestRender() }
        addChild(resourceList)

        addChild(Spacer(1))
        addChild(DynamicBorder())
    }

    public func getResourceList() -> Component {
        resourceList
    }
}
