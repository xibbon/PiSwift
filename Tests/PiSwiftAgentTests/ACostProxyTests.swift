import Foundation
import Testing
import PiSwiftAI
@testable import PiSwiftAgent

@Test func proxyUsageCostProvenanceRoundTrip() throws {
    let data = Data(#"{"type":"done","reason":"stop","usage":{"input":1,"output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":2,"cost":{"input":0.1,"output":0.2,"cacheRead":0,"cacheWrite":0,"total":0.4,"totalFromProvider":true}}}"#.utf8)
    guard case .done(_, let usage) = try decodeProxyAssistantMessageEventJSON(data) else {
        Issue.record("Missing proxy done event")
        return
    }
    #expect(usage.cost.total == 0.4)
    #expect(usage.cost.totalFromProvider == true)

    let old = Data(#"{"type":"done","reason":"stop","usage":{"input":1,"output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":2,"cost":{"input":0.1,"output":0.2,"cacheRead":0,"cacheWrite":0,"total":0.3}}}"#.utf8)
    guard case .done(_, let restored) = try decodeProxyAssistantMessageEventJSON(old) else {
        Issue.record("Missing old proxy done event")
        return
    }
    #expect(restored.cost.totalFromProvider == nil)
}
