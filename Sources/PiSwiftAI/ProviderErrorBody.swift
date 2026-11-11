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

/// Add the deepest Foundation connection cause when a transport wraps it.
func providerErrorWithCause(_ error: Error) -> String {
    let message = error.localizedDescription
    var current: Error? = (error as? URLError)?.userInfo[NSUnderlyingErrorKey] as? Error
    var deepest: Error?
    for _ in 0..<5 {
        guard let cause = current else { break }
        deepest = cause
        current = (cause as? URLError)?.userInfo[NSUnderlyingErrorKey] as? Error
    }
    guard let deepest else { return message }
    var detail = deepest.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    if let posix = deepest as? POSIXError {
        let code = String(posix.code.rawValue)
        if !detail.contains(code) {
            detail = detail.isEmpty ? code : "\(detail) (\(code))"
        }
    } else {
        let description = String(describing: deepest)
        if description.contains("NSPOSIXErrorDomain"),
           let range = description.range(of: #"Code=([0-9]+)"#, options: .regularExpression) {
            let code = String(description[range].dropFirst("Code=".count))
            if !detail.contains(code) { detail = "\(detail) (\(code))" }
        }
    }
    guard !detail.isEmpty, !message.contains(detail) else { return message }
    return message.isEmpty ? detail : "\(message): \(detail)"
}
