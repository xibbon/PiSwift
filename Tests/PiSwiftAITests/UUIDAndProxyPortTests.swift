import Foundation
import Testing
@testable import PiSwiftAI

private func uuidPortTimestamp(_ uuid: String) -> Int64? {
    Int64(uuid.replacingOccurrences(of: "-", with: "").prefix(12), radix: 16)
}

@Test func uuidV7OrdersOrdinaryIdsAndPreservesFollowerTimestamps() throws {
    let timestamp: Int64 = 0x0123456789ab
    var generator = UUIDV7Generator()
    let random = [UInt8](repeating: 1, count: 16)
    let first = try generator.generate(now: timestamp, randomBytes: random)
    let second = try generator.generate(now: timestamp, randomBytes: random)
    let rollback = try generator.generate(now: timestamp - 1, randomBytes: random)
    let advance = try generator.generate(now: timestamp + 1, randomBytes: random)
    let ordinary = [first, second, rollback, advance]
    let followers = try (0..<2).map { _ in try generator.generate(timestampMs: timestamp - 1000, now: timestamp + 2, randomBytes: random) }
    let pattern = #"^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#
    for id in ordinary + followers { #expect(id.range(of: pattern, options: .regularExpression) != nil) }
    #expect(ordinary == ordinary.sorted())
    #expect(Set(ordinary).count == ordinary.count)
    #expect(ordinary.compactMap(uuidPortTimestamp) == [timestamp, timestamp, timestamp, timestamp + 1])
    #expect(followers.compactMap(uuidPortTimestamp) == [timestamp - 1000, timestamp - 1000])
    #expect(Set(followers).count == 2)
    let afterFollower = try generator.generate(now: timestamp, randomBytes: random)
    #expect(uuidPortTimestamp(afterFollower) == timestamp + 1)
}

@Test func uuidV7UsesFreshTailRandomness() throws {
    var generator = UUIDV7Generator()
    let first = try generator.generate(timestampMs: 0x0123456789ab, now: 0, randomBytes: [UInt8](repeating: 1, count: 16))
    let second = try generator.generate(timestampMs: 0x0123456789ab, now: 0, randomBytes: [UInt8](repeating: 2, count: 16))
    #expect(String(first.suffix(8)) == "01010101")
    #expect(String(second.suffix(8)) == "02020202")
}

@Test(arguments: [Int64(0), 0xffffffffffff])
func uuidV7AcceptsTimestampBoundaries(_ timestamp: Int64) throws {
    var generator = UUIDV7Generator()
    #expect(uuidPortTimestamp(try generator.generate(timestampMs: timestamp, now: 0)) == timestamp)
    #expect(uuidPortTimestamp(try uuidv7(timestampMs: timestamp)) == timestamp)
}

@Test(arguments: [Int64(-1), 0x1000000000000, Int64.min, Int64.max])
func uuidV7RejectsInvalidTimestamp(_ timestamp: Int64) {
    var generator = UUIDV7Generator()
    #expect(throws: StreamError.self) { try generator.generate(timestampMs: timestamp, now: 0) }
}

@Test func uuidV7RejectsSequenceExhaustion() {
    var generator = UUIDV7Generator()
    generator.sequence = (1 << 41) - 1
    #expect(throws: StreamError.self) { try generator.generate(now: 0) }
}

@Test func uuidV7ConcurrentCallsRemainUnique() async throws {
    let ids = try await withThrowingTaskGroup(of: String.self, returning: [String].self) { group in
        for _ in 0..<128 { group.addTask { try uuidv7(timestampMs: 0x0123456789ab) } }
        var ids: [String] = []
        for try await id in group { ids.append(id) }
        return ids
    }
    #expect(ids.count == 128)
    #expect(Set(ids).count == 128)
}

@Test(arguments: [
    ("https://example.com", true), ("https://api.example.com", true),
    ("https://wildcard.org", true), ("https://api.wildcard.org", true),
    ("https://star.net", true), ("https://api.star.net", true),
    ("https://notexample.com", false), ("https://example.com.evil.test", false),
    ("https://[::1]:80", true), ("https://[2001:db8::1]", true),
    ("https://127.0.0.1:8080", true), ("https://127.0.0.1:3000", false),
])
func noProxyMatchesUpstreamURLCases(_ target: String, _ expected: Bool) throws {
    let entries = parseNoProxy(env: ["NO_PROXY": "example.com, .wildcard.org, *.star.net, ::1, [2001:db8::1], 127.0.0.1:8080"])
    let url = try #require(URL(string: target))
    #expect(shouldBypassProxy(host: url.host, port: url.port ?? (url.scheme == "https" ? 443 : 80), noProxy: entries) == expected)
}

@Test func noProxyParsesWhitespaceAliasesAndPorts() {
    #expect(parseNoProxy(env: ["no_proxy": "one.test two.test,\tthree.test\nfour.test"]) == ["one.test", "two.test", "three.test", "four.test"])
    #expect(parseNoProxy(env: ["NO_PROXY": "upper.test", "no_proxy": "lower.test"]) == ["upper.test"])
    #expect(parseNoProxyEntry("[2001:db8::1]:443")?.host == "2001:db8::1")
    #expect(parseNoProxyEntry("[2001:db8::1]:443")?.port == 443)
    #expect(parseNoProxyEntry("EXAMPLE.COM:8080suffix")?.port == 8080)
    #expect(shouldBypassProxy(host: "API.EXAMPLE.COM", port: 443, noProxy: ["example.com:443"]))
    #expect(!shouldBypassProxy(host: "api.example.com", port: 80, noProxy: ["example.com:443"]))
    #expect(shouldBypassProxy(host: "[::1]", port: 80, noProxy: ["::1"]))
    #expect(!shouldBypassProxy(host: nil, noProxy: ["*"]))
    #expect(shouldBypassProxy(host: "anything.invalid", noProxy: ["*"]))
    #expect(!shouldBypassProxy(host: "anything.invalid", noProxy: ["*", "example.com"]))
}
