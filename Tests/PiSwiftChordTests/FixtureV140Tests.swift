import CryptoKit
import Foundation
import Testing
import PiSwiftChord

private func v140Require<T>(_ value: T?) throws -> T { try #require(value) }

private func v140Fixture(_ name: String) throws -> JSONValue {
    let url = try v140Require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    // The generator executes v1.4.0 and records the digest of its output.
    // The frozen file supplies the same inputs and output without duplicate data.
    let manifest = try JSONValue(jsonData: Data(contentsOf: url))
    #expect(manifest["upstream"] == "pi-mono v1.4.0")
    let frozenName = try v140Require(manifest["frozenFixture"]?.stringValue)
    let frozenURL = try v140Require(Bundle.module.url(forResource: frozenName, withExtension: "json", subdirectory: "Fixtures"))
    let frozen = try JSONValue(jsonData: Data(contentsOf: frozenURL))
    let payload = try v140Require(frozen[v140Require(manifest["payload"]?.stringValue)])
    let bytes = Data(try payload.jsonText().utf8)
    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    #expect(digest == manifest["sha256"]?.stringValue)
    #expect(payload.arrayValue?.count == manifest["count"]?.intValue)
    return frozen
}
private func v140Matches(_ value: JSONValue, _ expected: JSONValue) throws -> Bool {
    let text = try value.jsonText()
    if let digest = expected["sha256"]?.stringValue {
        let bytes = Data(text.utf8)
        return bytes.count == expected["length"]?.intValue &&
            SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == digest
    }
    return try Array(text.utf8) == Array((expected.stringValue ?? expected.jsonText()).utf8)
}
private func v140Substitute(_ value: JSONValue, index: Int) -> JSONValue {
    if value["$index"]?.boolValue == true {
        return .number(Double(index * (value["scale"]?.intValue ?? 1) + (value["offset"]?.intValue ?? 0)))
    }
    switch value {
    case .array(let values): return .array(values.map { v140Substitute($0, index: index) })
    case .object(let object): return .object(JSONObject(object.map { ($0.key, v140Substitute($0.value, index: index)) }))
    default: return value
    }
}

@Suite struct FixtureV140Tests {
    @Test func oracleTagsAndJSONProvenanceMatchTag() throws {
        func load(_ name: String) throws -> JSONValue {
            let url = try v140Require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
            return try JSONValue(jsonData: Data(contentsOf: url))
        }
        for name in ["overlap-fixtures", "tracker-fixtures"] {
            #expect(try load(name)["upstream"] == "pi-mono v1.4.0")
        }
        let provenance = try v140Require(load("json-fixtures")["provenance"])
        #expect(provenance["reviewedAgainst"] == "pi-mono v1.4.0")
        #expect(provenance["oracle"] == "Node JSON.stringify, JSON.parse and Object.keys")
        #expect(provenance["upstreamSourceExecuted"] == false)
    }

    @Test func trackerPlansMatchTag() throws {
        let fixture = try v140Fixture("tracker-v140-fixtures")
        let cases = try v140Require(fixture["cases"]?.arrayValue)
        #expect(cases.count == 4)
        for row in cases {
            let tracker = try Delta.track(v140Require(row["base"]))
            let change = tracker.beginChange()
            var prepared: Delta.Prepared?
            func perform(_ step: JSONValue) throws {
                if step["op"] == "repeat" {
                    for index in 0..<(step["count"]?.intValue ?? 0) {
                        try perform(v140Substitute(v140Require(step["step"]), index: (step["from"]?.intValue ?? 0) + index))
                    }
                    return
                }
                var draft = try change.state
                for part in step["path"]?.arrayValue ?? [] {
                    if let key = part.stringValue { draft = try v140Require(try draft.child(key)) }
                    else { draft = try v140Require(try draft.child(v140Require(part.intValue))) }
                }
                switch step["op"]?.stringValue {
                case "push": try draft.append(contentsOf: step["values"]?.arrayValue ?? [])
                case "shift": _ = try draft.popFirst()
                case "pop": _ = try draft.popLast()
                case "splice": try draft.splice(v140Require(step["start"]?.intValue), deleteCount: step["deleteCount"]?.intValue, insert: step["values"]?.arrayValue ?? [])
                case "reverse": try draft.reverse()
                case "set": try draft.set(v140Require(step["key"]?.stringValue), v140Require(step["value"]))
                case "prepare": prepared = try change.prepare()
                case "adopt": try tracker.adopt(v140Require(prepared))
                default: Issue.record("Unknown fixture step: \(step)")
                }
            }
            let steps = try v140Require(row["steps"]?.arrayValue)
            let events = try v140Require(row["events"]?.arrayValue)
            #expect(steps.count == events.count)
            for (step, event) in zip(steps, events) {
                // Adoption does not access the revoked draft.
                if step["op"] == "adopt" { try tracker.adopt(v140Require(prepared)) }
                else { try perform(step) }
                if let ops = event["ops"] {
                    #expect(try v140Matches(JSONValue(encoding: v140Require(prepared).ops), ops))
                    #expect(try Delta.applyImmutable(v140Require(prepared).base, v140Require(prepared).ops) == v140Require(prepared).value)
                }
                if let expected = event["valueText"] {
                    let value = step["op"] == "adopt" ? tracker.value : try v140Require(prepared).value
                    #expect(try v140Matches(value, expected))
                }
            }
        }
    }

    @Test func immutableAppendCasesMatchTag() throws {
        let fixture = try v140Fixture("delta-v140-fixtures")
        let rows = try v140Require(fixture["apply"]?.arrayValue)
        #expect(rows.count == 13)
        for row in rows {
            let base = try JSONValue(jsonText: v140Require(row["initialText"]?.stringValue))
            do {
                let ops = try v140Require(row["ops"]).decode([Delta.Op].self)
                let result = try v140Require(try Delta.applyImmutable(base, ops))
                #expect(row["errorKind"] == nil)
                #expect(try v140Matches(result, v140Require(row["resultText"])))
            } catch {
                #expect(row["errorKind"] != nil)
                #expect(String(describing: error) == row["errorText"]?.stringValue)
            }
            #expect(try base.jsonText() == row["initialText"]?.stringValue)
        }
    }
}
