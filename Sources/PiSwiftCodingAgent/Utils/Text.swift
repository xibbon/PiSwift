import Foundation

/// Split one leading byte order mark from decoded text.
public func splitBom(_ content: String) -> (bom: String, text: String) {
    guard content.hasPrefix("\u{FEFF}") else { return ("", content) }
    return ("\u{FEFF}", String(content.dropFirst()))
}

/// Remove one leading byte order mark from decoded text.
// Keep untyped calls to the legacy tuple overload source-compatible.
@_disfavoredOverload
public func stripBom(_ content: String) -> String {
    splitBom(content).text
}
