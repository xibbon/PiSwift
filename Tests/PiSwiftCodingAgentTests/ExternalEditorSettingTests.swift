import Foundation
import Testing
@testable import PiSwiftCodingAgent

// settings-manager.ts:974-984 at v1.5.2.
@Suite("external editor setting")
struct ExternalEditorSettingTests {
    @Test("the setting wins, then VISUAL, then EDITOR, then nano")
    func commandOrder() {
        var settings = Settings()
        settings.externalEditor = "code --wait"
        let both = ["VISUAL": "vim", "EDITOR": "ed"]
        #expect(SettingsManager.inMemory(settings).getExternalEditorCommand(environment: both) == "code --wait")
        settings.externalEditor = "   "
        #expect(SettingsManager.inMemory(settings).getExternalEditorCommand(environment: both) == "vim")
        let manager = SettingsManager.inMemory()
        #expect(manager.getExternalEditorCommand(environment: ["VISUAL": "", "EDITOR": "ed"]) == "ed")
        #expect(manager.getExternalEditorCommand(environment: [:]) == "nano")
    }
}
