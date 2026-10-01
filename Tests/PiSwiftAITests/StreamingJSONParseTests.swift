import Foundation
import Testing
@testable import PiSwiftAI

// The parser before it was made linear, kept as the reference: the new one must
// return exactly the same results, only without the cubic cost.
private func referenceParseStreamingJSON(_ partialJson: String?) -> [String: AnyCodable] {
    guard let partialJson, !partialJson.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return [:]
    }

    if let object = referenceParseJSONObject(partialJson) {
        return object.mapValues { AnyCodable($0) }
    }

    var trimmed = partialJson
    while !trimmed.isEmpty {
        trimmed.removeLast()
        if let object = referenceParseJSONObject(trimmed) {
            return object.mapValues { AnyCodable($0) }
        }
    }

    return [:]
}

private func referenceParseJSONObject(_ string: String) -> [String: Any]? {
    guard let data = string.data(using: .utf8) else {
        return nil
    }
    guard let json = try? JSONSerialization.jsonObject(with: data, options: []),
          let object = json as? [String: Any] else {
        return nil
    }
    return object
}

@Test func streamingJSONParsesCompleteObject() {
    let parsed = parseStreamingJSON(#"{"path": "/tmp/a.gd", "line": 3, "force": true, "none": null, "edits": [{"old": "a"}]}"#)
    #expect(parsed == [
        "path": AnyCodable("/tmp/a.gd"),
        "line": AnyCodable(3),
        "force": AnyCodable(true),
        "none": AnyCodable(NSNull()),
        "edits": AnyCodable([["old": "a"]]),
    ])
}

// Tool calls are finalized with this function too, so anything cut off must come
// back empty rather than run with partial arguments.
@Test(arguments: [
    #"{"path": "/tmp/a.gd", "content": ""#,
    #"{"path": "/tmp/a.gd", "content": "extends Node\nvar sp"#,
    #"{"command": "rm -rf /tmp/project/build/"#,
    #"{"command": "sleep 5", "timeout": 30"#,
    #"{"path": "/tmp/a.gd", "cont"#,
    #"{"edits": [{"old": "a", "new": "b"}]"#,
    "{",
])
func streamingJSONRejectsCutOffToolCalls(_ input: String) {
    #expect(parseStreamingJSON(input).isEmpty)
}

@Test func streamingJSONIgnoresTextAfterTheObject() {
    #expect(parseStreamingJSON(#"{"a": 1} trailing"#) == ["a": AnyCodable(1)])
    #expect(parseStreamingJSON("  {\"a\": 1}  \n") == ["a": AnyCodable(1)])
    #expect(parseStreamingJSON(#"{"a": "}"} {"b": 2}"#) == ["a": AnyCodable("}")])
}

@Test func streamingJSONRejectsNonObjects() {
    #expect(parseStreamingJSON(nil).isEmpty)
    #expect(parseStreamingJSON("   ").isEmpty)
    #expect(parseStreamingJSON("[1, 2]").isEmpty)
    #expect(parseStreamingJSON(#""text""#).isEmpty)
}

@Test func streamingJSONMatchesPreviousParserOnEveryPrefix() throws {
    let arguments: [String: Any] = [
        "path": "/tmp/reel build/main.gd",
        "content": "extends Node3D\n\t# \"quoted\" \\ back\\slash é 😀\nvar speed := 1.5\n",
        "count": 30,
        "ratio": -1.5e3,
        "force": true,
        "none": NSNull(),
        "edits": [["old": "a", "new": "b}]"]],
    ]
    let full = try #require(String(data: JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]), encoding: .utf8))
    var prefix = ""
    var mismatches: [String] = []
    for character in full {
        prefix.append(character)
        for input in [prefix, prefix + " trailing", prefix + "}", prefix + "\"}", "\u{FEFF}" + prefix + "x"] {
            if parseStreamingJSON(input) != referenceParseStreamingJSON(input) {
                mismatches.append(input)
            }
        }
    }
    #expect(mismatches.isEmpty, "\(mismatches.prefix(3))")
    #expect(parseStreamingJSON(full)["content"]?.value as? String == arguments["content"] as? String)
}

// Providers re-read the whole text on every chunk, so each call must stay cheap.
// The budget is checked inside the loop so a regression fails in seconds instead
// of running for minutes.
@Test func streamingJSONStaysFastForLargeToolCalls() throws {
    let content = String(repeating: "\tvar reel_tuning := 1.5 # \"wiggle\" amount\n", count: 600)
    let full = try #require(String(data: JSONSerialization.data(withJSONObject: ["path": "/tmp/big.gd", "content": content]), encoding: .utf8))
    #expect(full.utf8.count > 25_000)
    let characters = Array(full)
    let deadline = ContinuousClock.now + .seconds(10)
    var partial = ""
    var earlyResults = 0
    for start in stride(from: 0, to: characters.count, by: 4) {
        let end = min(start + 4, characters.count)
        partial.append(contentsOf: characters[start..<end])
        if end < characters.count && !parseStreamingJSON(partial).isEmpty {
            earlyResults += 1
        }
        if ContinuousClock.now > deadline {
            Issue.record("Streaming took over 10 s, stopped after \(partial.utf8.count) of \(full.utf8.count) bytes")
            return
        }
    }
    #expect(earlyResults == 0)
    #expect(parseStreamingJSON(partial)["content"]?.value as? String == content)
}
