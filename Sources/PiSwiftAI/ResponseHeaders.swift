import Foundation

func responseHeaders(_ response: HTTPURLResponse) -> [String: String] {
    var headers: [String: String] = [:]
    for (key, value) in response.allHeaderFields {
        headers[String(describing: key)] = String(describing: value)
    }
    return headers
}
