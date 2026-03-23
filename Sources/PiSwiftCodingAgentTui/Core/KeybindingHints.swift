import Foundation
import MiniTui
import PiSwiftCodingAgent

/// Utilities for formatting keybinding hints in the UI.

/// Format keys array as display string (e.g., ["ctrl+c", "escape"] -> "ctrl+c/escape").
public func formatKeys(_ keys: [KeyId]) -> String {
    if keys.isEmpty { return "" }
    if keys.count == 1 { return keys[0] }
    return keys.joined(separator: "/")
}

/// Get display string for an editor action.
public func editorKey(_ action: EditorAction) -> String {
    return formatKeys(getKeybindings().getKeys(action.keybinding))
}

/// Get display string for an app action.
public func appKey(_ keybindings: KeybindingsManager, _ action: AppAction) -> String {
    return formatKeys(keybindings.getKeys(action))
}

/// Format a keybinding hint with consistent styling: dim key, muted description.
/// Looks up the key from editor keybindings automatically.
///
/// - Parameters:
///   - action: Editor action name (e.g., .selectConfirm, .expandTools)
///   - description: Description text (e.g., "to expand", "cancel")
/// - Returns: Formatted string with dim key and muted description
public func keyHint(_ action: EditorAction, _ description: String) -> String {
    return theme.fg(.dim, editorKey(action)) + theme.fg(.muted, " \(description)")
}

/// Format a keybinding hint for app-level actions.
/// Requires the KeybindingsManager instance.
///
/// - Parameters:
///   - keybindings: KeybindingsManager instance
///   - action: App action name (e.g., .interrupt, .externalEditor)
///   - description: Description text
/// - Returns: Formatted string with dim key and muted description
public func appKeyHint(_ keybindings: KeybindingsManager, _ action: AppAction, _ description: String) -> String {
    return theme.fg(.dim, appKey(keybindings, action)) + theme.fg(.muted, " \(description)")
}

/// Format a raw key string with description (for non-configurable keys like ↑↓).
///
/// - Parameters:
///   - key: Raw key string
///   - description: Description text
/// - Returns: Formatted string with dim key and muted description
public func rawKeyHint(_ key: String, _ description: String) -> String {
    return theme.fg(.dim, key) + theme.fg(.muted, " \(description)")
}
