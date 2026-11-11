import Foundation

package func toCodemodeIdentifier(_ name: String) -> String {
    var result = ""
    for scalar in name.unicodeScalars {
        let ascii = scalar.value
        let valid = (65...90).contains(ascii) || (97...122).contains(ascii) || ascii == 95 || ascii == 36 ||
            (!result.isEmpty && (48...57).contains(ascii))
        result += valid ? String(scalar) : "_"
    }
    return result.isEmpty ? "_" : result
}

package func codemodeToolIdentifierCollision(_ entries: [(name: String, identifier: String)]) -> String? {
    var namesByIdentifier: [String: String] = [:]
    for (name, identifier) in entries {
        if let previous = namesByIdentifier[identifier] {
            return "Tools \"\(previous)\" and \"\(name)\" use the same JavaScript identifier \"\(identifier)\"."
        }
        namesByIdentifier[identifier] = name
    }
    return nil
}

package func codemodePreview(_ value: String, limit: Int) -> String {
    let utf16 = value as NSString
    guard utf16.length > limit else { return value }
    var end = max(0, limit - 3)
    if end > 0, end < utf16.length,
       (0xD800...0xDBFF).contains(Int(utf16.character(at: end - 1))),
       (0xDC00...0xDFFF).contains(Int(utf16.character(at: end))) {
        end -= 1
    }
    return utf16.substring(to: end) + "..."
}
