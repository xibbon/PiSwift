import Foundation
import MiniTui
import PiSwiftCodingAgent
import PiSwiftCodingAgentTui

public func selectProjectTrustOption(
    cwd: String,
    settingsManager: SettingsManager,
    includeSessionOnly: Bool = true
) async -> ProjectTrustOption? {
    await withCheckedContinuation { continuation in
        Task { @MainActor in
            initTheme(settingsManager.getTheme(), enableWatcher: true)
            let ui = TUI(terminal: ProcessTerminal())
            var resolved = false
            let options = getProjectTrustOptions(cwd, includeSessionOnly: includeSessionOnly)

            let selector = ProjectTrustSelectorComponent(
                cwd: cwd,
                options: options,
                onSelect: { option in
                    guard !resolved else { return }
                    resolved = true
                    ui.stop()
                    stopThemeWatcher()
                    continuation.resume(returning: option)
                },
                onCancel: {
                    guard !resolved else { return }
                    resolved = true
                    ui.stop()
                    stopThemeWatcher()
                    continuation.resume(returning: nil)
                }
            )

            ui.addChild(selector)
            ui.setFocus(selector)
            ui.start()
        }
    }
}
