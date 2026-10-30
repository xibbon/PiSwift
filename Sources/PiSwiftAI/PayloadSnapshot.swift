import Foundation

/// Apply the callback after provider fields have been assembled. Keep the returned bytes
/// so fields that are absent from an SDK request type still reach the provider.
func transformPayload(_ handler: PayloadHandler?, data: Data) async throws -> Data {
    guard let handler else { return data }
    let snapshot = PayloadSnapshot(json: String(decoding: data, as: UTF8.self))
    guard let replacement = try await handler(snapshot) else { return data }
    let replacementData = Data(replacement.json.utf8)
    guard case .object = try OrderedJSON.parse(replacement.json) else {
        throw PayloadError.expectedObject
    }
    return replacementData
}

func transformPayload(_ handler: PayloadHandler?, jsonObject: Any) async throws -> Data {
    let data = try JSONSerialization.data(withJSONObject: jsonObject)
    return try await transformPayload(handler, data: data)
}

private enum PayloadError: LocalizedError {
    case expectedObject

    var errorDescription: String? { "The provider request payload must be a JSON object" }
}
