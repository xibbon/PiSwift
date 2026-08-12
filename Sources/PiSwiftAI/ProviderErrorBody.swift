import Foundation

struct NormalizedProviderErrorBody: Sendable, Equatable {
    let body: String?
    let message: String
    let messageCarriesBody: Bool
}

func normalizeProviderErrorBody(message: String, candidate: Any?) -> NormalizedProviderErrorBody {
    let body: String?
    if let candidate = candidate as? String {
        body = candidate
    } else if let dictionary = candidate as? [String: Any], !dictionary.isEmpty,
              JSONSerialization.isValidJSONObject(dictionary),
              let data = try? JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys]) {
        body = String(data: data, encoding: .utf8)
    } else {
        body = nil
    }

    guard let body, !body.isEmpty else {
        return NormalizedProviderErrorBody(body: nil, message: message, messageCarriesBody: true)
    }
    return NormalizedProviderErrorBody(body: body, message: body, messageCarriesBody: message.contains(body))
}
