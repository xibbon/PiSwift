import Foundation
import MiniTui
import PiSwiftCodingAgent

public struct FirstTimeSetupResult: Sendable, Equatable {
    public var themeName: String
    public var shareAnalytics: Bool

    public init(themeName: String, shareAnalytics: Bool) {
        self.themeName = themeName
        self.shareAnalytics = shareAnalytics
    }
}

public final class FirstTimeSetupComponent: Container {
    private enum Step {
        case theme
        case analytics
    }

    private struct SetupOption {
        var label: String
        var themeName: String?
        var shareAnalytics: Bool?
    }

    private let themeOptions = [
        SetupOption(label: "Dark", themeName: "dark", shareAnalytics: nil),
        SetupOption(label: "Light", themeName: "light", shareAnalytics: nil),
    ]
    private let analyticsOptions = [
        SetupOption(label: "Share anonymous usage data", themeName: nil, shareAnalytics: true),
        SetupOption(label: "Don't share", themeName: nil, shareAnalytics: false),
    ]

    private var step: Step = .theme
    private var selectedThemeIndex: Int
    private var selectedAnalyticsIndex = 0
    private let detectedThemeName: String
    private let listContainer: Container
    private let onThemePreviewCallback: (String) -> Void
    private let onSubmitCallback: (FirstTimeSetupResult) -> Void
    private let onCancelCallback: () -> Void

    public init(
        detectedThemeName: String,
        onThemePreview: @escaping (String) -> Void,
        onSubmit: @escaping (FirstTimeSetupResult) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.detectedThemeName = detectedThemeName
        self.selectedThemeIndex = detectedThemeName == "light" ? 1 : 0
        self.listContainer = Container()
        self.onThemePreviewCallback = onThemePreview
        self.onSubmitCallback = onSubmit
        self.onCancelCallback = onCancel
        super.init()

        update()
    }

    private func update() {
        clear()
        addChild(DynamicBorder())
        addChild(Spacer(1))
        addChild(Text(theme.fg(.accent, "Welcome to \(APP_NAME), the minimal coding agent."), paddingX: 1, paddingY: 0))
        addChild(Spacer(1))

        switch step {
        case .theme:
            addChild(Text(theme.fg(.text, "Pick a theme."), paddingX: 1, paddingY: 0))
            addChild(Text(theme.fg(.muted, "Detected system appearance: \(detectedThemeName)"), paddingX: 1, paddingY: 0))
        case .analytics:
            addChild(Text(theme.fg(.text, "Opt in to anonymous usage data sharing?"), paddingX: 1, paddingY: 0))
            addChild(Text(
                theme.fg(.muted, "Opting in stores a tracking identifier in settings.json and enables anonymous usage analytics."),
                paddingX: 1,
                paddingY: 0
            ))
        }

        addChild(Spacer(1))
        addChild(listContainer)
        addChild(Spacer(1))
        addChild(Text(theme.fg(.dim, "up/down navigate  enter \(step == .theme ? "continue" : "finish")  esc skip setup"), paddingX: 1, paddingY: 0))
        addChild(Spacer(1))
        addChild(DynamicBorder())

        updateList()
    }

    private func updateList() {
        listContainer.clear()
        let options = step == .theme ? themeOptions : analyticsOptions
        let selectedIndex = step == .theme ? selectedThemeIndex : selectedAnalyticsIndex

        for (index, option) in options.enumerated() {
            let isSelected = index == selectedIndex
            let prefix = isSelected ? "> " : "  "
            let line = isSelected
                ? theme.fg(.accent, prefix + option.label)
                : prefix + theme.fg(.text, option.label)
            listContainer.addChild(Text(line, paddingX: 1, paddingY: 0))
        }
    }

    private func moveSelection(_ delta: Int) {
        switch step {
        case .theme:
            let next = max(0, min(themeOptions.count - 1, selectedThemeIndex + delta))
            if next != selectedThemeIndex {
                selectedThemeIndex = next
                if let themeName = themeOptions[selectedThemeIndex].themeName {
                    onThemePreviewCallback(themeName)
                }
            }
        case .analytics:
            selectedAnalyticsIndex = max(0, min(analyticsOptions.count - 1, selectedAnalyticsIndex + delta))
        }
        update()
    }

    public override func handleInput(_ keyData: String) {
        if isArrowUp(keyData) || keyData == "k" {
            moveSelection(-1)
            return
        }
        if isArrowDown(keyData) || keyData == "j" {
            moveSelection(1)
            return
        }
        if isEnter(keyData) || keyData == "\n" {
            switch step {
            case .theme:
                step = .analytics
                update()
            case .analytics:
                let selectedTheme = themeOptions[selectedThemeIndex].themeName ?? "dark"
                let shareAnalytics = analyticsOptions[selectedAnalyticsIndex].shareAnalytics ?? false
                onSubmitCallback(FirstTimeSetupResult(themeName: selectedTheme, shareAnalytics: shareAnalytics))
            }
            return
        }
        if isEscape(keyData) || isCtrlC(keyData) {
            onCancelCallback()
        }
    }
}
