import Foundation

func openAIRequestBodyData(_ request: URLRequest) -> Data? {
    if let body = request.httpBody {
        return body.isEmpty ? nil : body
    }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count > 0 else { break }
        data.append(buffer, count: count)
    }
    return data.isEmpty ? nil : data
}

func rewritingOpenAIRequestBodyData(
    _ request: URLRequest,
    _ mutate: (Data) -> Data?
) -> URLRequest {
    guard let body = openAIRequestBodyData(request),
          let updatedBody = mutate(body) else { return request }
    var updated = request
    updated.httpBodyStream = nil
    updated.httpBody = updatedBody
    return updated
}

func rewritingOpenAIRequestBody(
    _ request: URLRequest,
    _ mutate: (inout [String: Any]) -> Bool
) -> URLRequest {
    rewritingOpenAIRequestBodyData(request) { body in
        guard var payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              mutate(&payload) else { return nil }
        return try? JSONSerialization.data(withJSONObject: payload)
    }
}
