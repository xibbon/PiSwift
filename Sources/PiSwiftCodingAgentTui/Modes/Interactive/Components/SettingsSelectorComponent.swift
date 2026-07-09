import Foundation
import MiniTui
import PiSwiftAgent
import PiSwiftAI
import PiSwiftCodingAgent

private let thinkingDescriptions: [ThinkingLevel: String] = [
    .off: "No reasoning",
    .minimal: "Very brief reasoning (~1k tokens)",
    .low: "Light reasoning (~2k tokens)",
    .medium: "Moderate reasoning (~8k tokens)",
    .high: "Deep reasoning (~16k tokens)",
    .xhigh: "Maximum reasoning (~32k tokens)",
]

public struct SettingsConfig: Sendable {
    public var autoCompact: Bool
    public var showImages: Bool
    public var autoResizeImages: Bool
    public var blockImages: Bool
    public var enableSkillCommands: Bool
    public var steeringMode: String
    public var followUpMode: String
    public var transport: Transport
    public var thinkingLevel: ThinkingLevel
    public var availableThinkingLevels: [ThinkingLevel]
    public var currentTheme: String
    public var availableThemes: [String]
    public var hideThinkingBlock: Bool
    public var collapseChangelog: Bool
    public var quietStartup: Bool
    public var doubleEscapeAction: String
    public var editorPaddingX: Int
    public var autocompleteMaxVisible: Int

    public init(
        autoCompact: Bool,
        showImages: Bool,
        autoResizeImages: Bool,
        blockImages: Bool,
        enableSkillCommands: Bool,
        steeringMode: String,
        followUpMode: String,
        transport: Transport,
        thinkingLevel: ThinkingLevel,
        availableThinkingLevels: [ThinkingLevel],
        currentTheme: String,
        availableThemes: [String],
        hideThinkingBlock: Bool,
        collapseChangelog: Bool,
        quietStartup: Bool,
        doubleEscapeAction: String,
        editorPaddingX: Int,
        autocompleteMaxVisible: Int
    ) {
        self.autoCompact = autoCompact
        self.showImages = showImages
        self.autoResizeImages = autoResizeImages
        self.blockImages = blockImages
        self.enableSkillCommands = enableSkillCommands
        self.steeringMode = steeringMode
        self.followUpMode = followUpMode
        self.transport = transport
        self.thinkingLevel = thinkingLevel
        self.availableThinkingLevels = availableThinkingLevels
        self.currentTheme = currentTheme
        self.availableThemes = availableThemes
        self.hideThinkingBlock = hideThinkingBlock
        self.collapseChangelog = collapseChangelog
        self.quietStartup = quietStartup
        self.doubleEscapeAction = doubleEscapeAction
        self.editorPaddingX = editorPaddingX
        self.autocompleteMaxVisible = autocompleteMaxVisible
    }
}

public struct SettingsCallbacks {
    public var onAutoCompactChange: (Bool) -> Void
    public var onShowImagesChange: (Bool) -> Void
    public var onAutoResizeImagesChange: (Bool) -> Void
    public var onBlockImagesChange: (Bool) -> Void
    public var onEnableSkillCommandsChange: (Bool) -> Void
    public var onSteeringModeChange: (String) -> Void
    public var onFollowUpModeChange: (String) -> Void
    public var onTransportChange: (Transport) -> Void
    public var onThinkingLevelChange: (ThinkingLevel) -> Void
    public var onThemeChange: (String) -> Void
    public var onThemePreview: ((String) -> Void)?
    public var onHideThinkingBlockChange: (Bool) -> Void
    public var onCollapseChangelogChange: (Bool) -> Void
    public var onQuietStartupChange: (Bool) -> Void
    public var onDoubleEscapeActionChange: (String) -> Void
    public var onEditorPaddingXChange: (Int) -> Void
    public var onAutocompleteMaxVisibleChange: (Int) -> Void
    public var onCancel: () -> Void

    public init(
        onAutoCompactChange: @escaping (Bool) -> Void,
        onShowImagesChange: @escaping (Bool) -> Void,
        onAutoResizeImagesChange: @escaping (Bool) -> Void,
        onBlockImagesChange: @escaping (Bool) -> Void,
        onEnableSkillCommandsChange: @escaping (Bool) -> Void,
        onSteeringModeChange: @escaping (String) -> Void,
        onFollowUpModeChange: @escaping (String) -> Void,
        onTransportChange: @escaping (Transport) -> Void,
        onThinkingLevelChange: @escaping (ThinkingLevel) -> Void,
        onThemeChange: @escaping (String) -> Void,
        onThemePreview: ((String) -> Void)? = nil,
        onHideThinkingBlockChange: @escaping (Bool) -> Void,
        onCollapseChangelogChange: @escaping (Bool) -> Void,
        onQuietStartupChange: @escaping (Bool) -> Void,
        onDoubleEscapeActionChange: @escaping (String) -> Void,
        onEditorPaddingXChange: @escaping (Int) -> Void,
        onAutocompleteMaxVisibleChange: @escaping (Int) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onAutoCompactChange = onAutoCompactChange
        self.onShowImagesChange = onShowImagesChange
        self.onAutoResizeImagesChange = onAutoResizeImagesChange
        self.onBlockImagesChange = onBlockImagesChange
        self.onEnableSkillCommandsChange = onEnableSkillCommandsChange
        self.onSteeringModeChange = onSteeringModeChange
        self.onFollowUpModeChange = onFollowUpModeChange
        self.onTransportChange = onTransportChange
        self.onThinkingLevelChange = onThinkingLevelChange
        self.onThemeChange = onThemeChange
        self.onThemePreview = onThemePreview
        self.onHideThinkingBlockChange = onHideThinkingBlockChange
        self.onCollapseChangelogChange = onCollapseChangelogChange
        self.onQuietStartupChange = onQuietStartupChange
        self.onDoubleEscapeActionChange = onDoubleEscapeActionChange
        self.onEditorPaddingXChange = onEditorPaddingXChange
        self.onAutocompleteMaxVisibleChange = onAutocompleteMaxVisibleChange
        self.onCancel = onCancel
    }
}

private final class SelectSubmenu: Container {
    private let selectList: SelectList

    init(
        title: String,
        description: String,
        options: [SelectItem],
        currentValue: String,
        onSelect: @escaping (String) -> Void,
        onCancel: @escaping () -> Void,
        onSelectionChange: ((String) -> Void)?
    ) {
        self.selectList = SelectList(items: options, maxVisible: min(options.count, 10), theme: getSelectListTheme())
        super.init()

        addChild(Text(theme.bold(theme.fg(.accent, title)), paddingX: 0, paddingY: 0))

        if !description.isEmpty {
            addChild(Spacer(1))
            addChild(Text(theme.fg(.muted, description), paddingX: 0, paddingY: 0))
        }

        addChild(Spacer(1))

        if let idx = options.firstIndex(where: { $0.value == currentValue }) {
            selectList.setSelectedIndex(idx)
        }

        selectList.onSelect = { item in
            onSelect(item.value)
        }
        selectList.onCancel = onCancel
        if let onSelectionChange {
            selectList.onSelectionChange = { item in
                onSelectionChange(item.value)
            }
        }

        addChild(selectList)
        addChild(Spacer(1))
        addChild(Text(theme.fg(.dim, "  Enter to select · Esc to go back"), paddingX: 0, paddingY: 0))
    }

    override func handleInput(_ data: String) {
        selectList.handleInput(data)
    }
}

public final class SettingsSelectorComponent: Container {
    private let settingsList: SettingsList

    public init(config: SettingsConfig, callbacks: SettingsCallbacks) {
        let supportsImages = getCapabilities().images != nil

        var items: [SettingItem] = [
            SettingItem(
                id: "autocompact",
                label: "Auto-compact",
                description: "Automatically compact context when it gets too large",
                currentValue: config.autoCompact ? "true" : "false",
                values: ["true", "false"]
            ),
            SettingItem(
                id: "steering-mode",
                label: "Steering mode",
                description: "Enter while streaming queues steering messages. 'one-at-a-time': deliver one, wait for response. 'all': deliver all at once.",
                currentValue: config.steeringMode,
                values: ["one-at-a-time", "all"]
            ),
            SettingItem(
                id: "follow-up-mode",
                label: "Follow-up mode",
                description: "Alt+Enter queues follow-up messages until agent stops. 'one-at-a-time': deliver one, wait for response. 'all': deliver all at once.",
                currentValue: config.followUpMode,
                values: ["one-at-a-time", "all"]
            ),
            SettingItem(
                id: "transport",
                label: "Transport",
                description: "Preferred transport for providers that support multiple transports",
                currentValue: config.transport.rawValue,
                values: ["sse", "websocket", "auto"]
            ),
            SettingItem(
                id: "hide-thinking",
                label: "Hide thinking",
                description: "Hide thinking blocks in assistant responses",
                currentValue: config.hideThinkingBlock ? "true" : "false",
                values: ["true", "false"]
            ),
            SettingItem(
                id: "collapse-changelog",
                label: "Collapse changelog",
                description: "Show condensed changelog after updates",
                currentValue: config.collapseChangelog ? "true" : "false",
                values: ["true", "false"]
            ),
            SettingItem(
                id: "quiet-startup",
                label: "Quiet startup",
                description: "Disable verbose printing at startup",
                currentValue: config.quietStartup ? "true" : "false",
                values: ["true", "false"]
            ),
            SettingItem(
                id: "double-escape-action",
                label: "Double-escape action",
                description: "Action when pressing Escape twice with empty editor",
                currentValue: config.doubleEscapeAction,
                values: ["tree", "fork", "none"]
            ),
            SettingItem(
                id: "autocomplete-max-visible",
                label: "Autocomplete max items",
                description: "Max visible items in autocomplete dropdown (3-20)",
                currentValue: String(config.autocompleteMaxVisible),
                values: ["3", "5", "7", "10", "15", "20"]
            ),
            SettingItem(
                id: "editor-padding-x",
                label: "Editor padding",
                description: "Horizontal padding inside the prompt editor (0-3)",
                currentValue: String(config.editorPaddingX),
                values: ["0", "1", "2", "3"]
            ),
            SettingItem(
                id: "thinking",
                label: "Thinking level",
                description: "Reasoning depth for thinking-capable models",
                currentValue: config.thinkingLevel.rawValue,
                submenu: { currentValue, done in
                    SelectSubmenu(
                        title: "Thinking Level",
                        description: "Select reasoning depth for thinking-capable models",
                        options: config.availableThinkingLevels.map { level in
                            SelectItem(value: level.rawValue, label: level.rawValue, description: thinkingDescriptions[level])
                        },
                        currentValue: currentValue,
                        onSelect: { value in
                            if let level = ThinkingLevel(rawValue: value) {
                                callbacks.onThinkingLevelChange(level)
                            }
                            done(value)
                        },
                        onCancel: { done(nil) },
                        onSelectionChange: nil
                    )
                }
            ),
            SettingItem(
                id: "theme",
                label: "Theme",
                description: "Color theme for the interface",
                currentValue: config.currentTheme,
                submenu: { currentValue, done in
                    SelectSubmenu(
                        title: "Theme",
                        description: "Select color theme",
                        options: config.availableThemes.map { SelectItem(value: $0, label: $0) },
                        currentValue: currentValue,
                        onSelect: { value in
                            callbacks.onThemeChange(value)
                            done(value)
                        },
                        onCancel: {
                            callbacks.onThemePreview?(currentValue)
                            done(nil)
                        },
                        onSelectionChange: { value in
                            callbacks.onThemePreview?(value)
                        }
                    )
                }
            ),
        ]

        if supportsImages {
            items.insert(
                SettingItem(
                    id: "show-images",
                    label: "Show images",
                    description: "Render images inline in terminal",
                    currentValue: config.showImages ? "true" : "false",
                    values: ["true", "false"]
                ),
                at: 1
            )
        }

        let autoResizeIndex = supportsImages ? 2 : 1
        items.insert(
            SettingItem(
                id: "auto-resize-images",
                label: "Auto-resize images",
                description: "Resize large images to 2000x2000 max for better model compatibility",
                currentValue: config.autoResizeImages ? "true" : "false",
                values: ["true", "false"]
            ),
            at: autoResizeIndex
        )

        let blockImagesIndex = autoResizeIndex + 1
        items.insert(
            SettingItem(
                id: "block-images",
                label: "Block images",
                description: "Prevent images from being sent to LLM providers",
                currentValue: config.blockImages ? "true" : "false",
                values: ["true", "false"]
            ),
            at: blockImagesIndex
        )

        let skillCommandsIndex = blockImagesIndex + 1
        items.insert(
            SettingItem(
                id: "skill-commands",
                label: "Skill commands",
                description: "Register skills as /skill:name commands",
                currentValue: config.enableSkillCommands ? "true" : "false",
                values: ["true", "false"]
            ),
            at: skillCommandsIndex
        )

        self.settingsList = SettingsList(
            items: items,
            maxVisible: 10,
            theme: getSettingsListTheme(),
            onChange: { id, newValue in
                switch id {
                case "autocompact":
                    callbacks.onAutoCompactChange(newValue == "true")
                case "show-images":
                    callbacks.onShowImagesChange(newValue == "true")
                case "auto-resize-images":
                    callbacks.onAutoResizeImagesChange(newValue == "true")
                case "block-images":
                    callbacks.onBlockImagesChange(newValue == "true")
                case "skill-commands":
                    callbacks.onEnableSkillCommandsChange(newValue == "true")
                case "steering-mode":
                    callbacks.onSteeringModeChange(newValue)
                case "follow-up-mode":
                    callbacks.onFollowUpModeChange(newValue)
                case "transport":
                    if let transport = Transport(rawValue: newValue) {
                        callbacks.onTransportChange(transport)
                    }
                case "hide-thinking":
                    callbacks.onHideThinkingBlockChange(newValue == "true")
                case "collapse-changelog":
                    callbacks.onCollapseChangelogChange(newValue == "true")
                case "quiet-startup":
                    callbacks.onQuietStartupChange(newValue == "true")
                case "double-escape-action":
                    callbacks.onDoubleEscapeActionChange(newValue)
                case "editor-padding-x":
                    if let value = Int(newValue) {
                        callbacks.onEditorPaddingXChange(value)
                    }
                case "autocomplete-max-visible":
                    if let value = Int(newValue) {
                        callbacks.onAutocompleteMaxVisibleChange(value)
                    }
                default:
                    break
                }
            },
            onCancel: callbacks.onCancel,
            options: SettingsListOptions(enableSearch: true)
        )

        super.init()
        addChild(DynamicBorder())
        addChild(settingsList)
        addChild(DynamicBorder())
    }

    public func getSettingsList() -> SettingsList {
        settingsList
    }
}
