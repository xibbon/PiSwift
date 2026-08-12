import Foundation
import OpenAI

struct OpenAISamplingParamsMiddleware: OpenAIMiddleware {
    let samplingParams: [String: AnyCodable]

    func intercept(request: URLRequest) -> URLRequest {
        let body = openAIRequestBodyData(request)
        guard !body.isEmpty,
              var payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return request
        }

        for (key, value) in samplingParams {
            payload[key] = value.jsonValue
        }

        guard let updatedBody = try? JSONSerialization.data(withJSONObject: payload) else {
            return request
        }
        var updated = request
        updated.httpBodyStream = nil
        updated.httpBody = updatedBody
        return updated
    }
}

private func openAIRequestBodyData(_ request: URLRequest) -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count > 0 {
            data.append(buffer, count: count)
        } else {
            break
        }
    }
    return data
}

func applyOpenAISamplingParams(
    data: Data,
    samplingParams: [String: AnyCodable]?
) -> Data {
    guard let samplingParams, !samplingParams.isEmpty else { return data }
    var request = URLRequest(url: URL(string: "https://localhost/")!)
    request.httpBody = data
    return OpenAISamplingParamsMiddleware(samplingParams: samplingParams)
        .intercept(request: request)
        .httpBody ?? data
}
