import Foundation
import OpenAI

struct OpenAISamplingParamsMiddleware: OpenAIMiddleware {
    let samplingParams: [String: AnyCodable]

    func intercept(request: URLRequest) -> URLRequest {
        return rewritingOpenAIRequestBody(request) { payload in
            for (key, value) in samplingParams {
                payload[key] = value.jsonValue
            }
            return true
        }
    }
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
