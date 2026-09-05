import Foundation

func stripUTF8BOM(_ data: Data) -> Data {
    data.starts(with: [0xef, 0xbb, 0xbf]) ? Data(data.dropFirst(3)) : data
}

public func collectSettingsDiagnostics(_ settingsManager: SettingsManager) -> [ResourceDiagnostic] {
    settingsManager.drainErrors().map { error in
        let source = error.path.map { "settings file \($0)" } ?? "\(error.scope) settings"
        return ResourceDiagnostic(type: "warning", message: "Invalid \(source): \(error.message)")
    }
}

public func deduplicateDiagnostics(_ diagnostics: [ResourceDiagnostic]) -> [ResourceDiagnostic] {
    struct Key: Hashable { let type: String; let message: String }
    var seen = Set<Key>()
    return diagnostics.filter { seen.insert(Key(type: $0.type, message: $0.message)).inserted }
}
