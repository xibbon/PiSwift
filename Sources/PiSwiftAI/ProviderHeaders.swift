import Foundation

/// Merges provider headers case-insensitively while preserving deletion markers.
public func mergeProviderHeaders(
    _ base: ProviderHeaders?,
    _ override: ProviderHeaders?
) -> ProviderHeaders? {
    guard base != nil || override != nil else { return nil }
    var merged = base ?? [:]
    for (name, value) in override ?? [:] {
        let lowercasedName = name.lowercased()
        let matchingNames = merged.keys.filter { $0.lowercased() == lowercasedName }
        for existingName in matchingNames {
            merged.removeValue(forKey: existingName)
        }
        merged.updateValue(value, forKey: name)
    }
    return merged
}

/// Returns headers that can be passed to APIs which cannot represent deletion markers.
public func providerHeadersToRecord(_ headers: ProviderHeaders?) -> [String: String]? {
    guard let headers else { return nil }
    var record: [String: String] = [:]
    for (name, value) in headers {
        if let value {
            record[name] = value
        }
    }
    return record.isEmpty ? nil : record
}

public func providerHeadersContain(_ headers: ProviderHeaders?, name: String) -> Bool {
    let expected = name.lowercased()
    return headers?.keys.contains { $0.lowercased() == expected } == true
}

public func providerHeaderValue(_ headers: ProviderHeaders?, name: String) -> String? {
    let expected = name.lowercased()
    guard let key = headers?.keys.first(where: { $0.lowercased() == expected }) else { return nil }
    return headers?[key] ?? nil
}

/// Applies provider headers after request defaults. `nil` removes an existing field.
public func applyProviderHeaders(_ headers: ProviderHeaders?, to request: inout URLRequest) {
    for (name, value) in headers ?? [:] {
        request.setValue(value, forHTTPHeaderField: name)
    }
}
