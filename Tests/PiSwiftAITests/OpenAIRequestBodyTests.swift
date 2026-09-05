import Foundation
import Testing
@testable import PiSwiftAI

private func openAIBodyTestRequest() -> URLRequest {
    var request = URLRequest(url: URL(string: "https://example.com/v1/responses")!)
    request.httpMethod = "POST"
    request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
    return request
}

@Test func openAIRequestBodyReaderUsesBody() {
    var request = openAIBodyTestRequest()
    let stream = InputStream(data: Data("stream".utf8))
    request.httpBodyStream = stream
    let body = Data("body".utf8)
    // Foundation clears the stream when the body is set.
    request.httpBody = body
    #expect(request.httpBodyStream == nil)
    #expect(openAIRequestBodyData(request) == body)
    #expect(stream.streamStatus == .notOpen)
}

@Test func openAIRequestBodyReaderDrainsLargeStream() {
    var request = openAIBodyTestRequest()
    let body = Data(repeating: 65, count: 12_345)
    let stream = InputStream(data: body)
    request.httpBodyStream = stream
    #expect(openAIRequestBodyData(request) == body)
    #expect(stream.streamStatus == .closed)
}

@Test func openAIRequestBodyReaderReturnsNilForMissingOrEmptyBody() {
    var request = openAIBodyTestRequest()
    #expect(openAIRequestBodyData(request) == nil)
    request.httpBody = Data()
    #expect(openAIRequestBodyData(request) == nil)
    request.httpBodyStream = InputStream(data: Data())
    #expect(openAIRequestBodyData(request) == nil)
}

@Test func openAIRequestBodyNoChangePreservesOriginalBytes() {
    var request = openAIBodyTestRequest()
    let body = Data("{ \"value\" : 1, \"name\" : \"sample\" }\n".utf8)
    request.httpBody = body
    let updated = rewritingOpenAIRequestBody(request) { payload in
        payload["value"] = 2
        return false
    }
    #expect(updated == request)
    #expect(updated.httpBody == body)
}

@Test func openAIRequestBodyNoChangeKeepsStreamIdentity() {
    var request = openAIBodyTestRequest()
    let stream = InputStream(data: Data("{\"value\":1}".utf8))
    request.httpBodyStream = stream
    let updated = rewritingOpenAIRequestBody(request) { _ in false }
    #expect(updated.httpBody == nil)
    #expect(updated.httpBodyStream === stream)
    #expect(request.httpBodyStream === stream)
    // The reader drains and closes the original stream, even when there is no change.
    #expect(stream.streamStatus == .closed)
}

@Test func openAIRequestBodyInvalidJSONAndArrayStayUnchanged() {
    for text in ["not JSON", "[1,2,3]"] {
        var request = openAIBodyTestRequest()
        let body = Data(text.utf8)
        request.httpBody = body
        var called = false
        let updated = rewritingOpenAIRequestBody(request) { _ in
            called = true
            return true
        }
        #expect(!called)
        #expect(updated == request)
        #expect(updated.httpBody == body)
    }
}

@Test func openAIRequestBodyMutationReplacesStreamAndPreservesHeaders() throws {
    var request = openAIBodyTestRequest()
    request.httpBodyStream = InputStream(data: Data("{\"value\":1,\"name\":\"sample\"}".utf8))
    let updated = rewritingOpenAIRequestBody(request) { payload in
        payload["value"] = 2
        return true
    }
    #expect(updated.httpBodyStream == nil)
    #expect(updated.allHTTPHeaderFields == request.allHTTPHeaderFields)
    #expect(updated.value(forHTTPHeaderField: "Content-Type") == "application/json; charset=utf-8")
    #expect(updated.url == request.url)
    #expect(updated.httpMethod == request.httpMethod)
    let body = try #require(updated.httpBody)
    let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(payload["value"] as? Int == 2)
    #expect(payload["name"] as? String == "sample")
}

@Test func openAIRequestBodyDataNoChangePreservesRawText() {
    var request = openAIBodyTestRequest()
    let body = Data("raw text\n".utf8)
    request.httpBody = body
    let updated = rewritingOpenAIRequestBodyData(request) { data in
        #expect(data == body)
        return nil
    }
    #expect(updated == request)
    #expect(updated.httpBody == body)
}

@Test func openAIRequestBodyDataMutationReplacesRawStream() {
    var request = openAIBodyTestRequest()
    request.httpBodyStream = InputStream(data: Data("raw text".utf8))
    let replacement = Data("updated text".utf8)
    let updated = rewritingOpenAIRequestBodyData(request) { data in
        #expect(data == Data("raw text".utf8))
        return replacement
    }
    #expect(updated.httpBodyStream == nil)
    #expect(updated.httpBody == replacement)
    #expect(updated.allHTTPHeaderFields == request.allHTTPHeaderFields)
}

@Test func openAIRequestBodyMissingBodySkipsMutation() {
    let request = openAIBodyTestRequest()
    var called = false
    let updated = rewritingOpenAIRequestBody(request) { _ in
        called = true
        return true
    }
    #expect(!called)
    #expect(updated == request)
    let dataUpdated = rewritingOpenAIRequestBodyData(request) { _ in
        called = true
        return Data()
    }
    #expect(!called)
    #expect(dataUpdated == request)
}
