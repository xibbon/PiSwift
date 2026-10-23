import CryptoKit
import Foundation
import Testing
import PiSwiftChord

private func v130Require<T>(_ value: T?) throws -> T { try #require(value) }

private func v130Fixture(_ name: String) throws -> JSONValue {
    let url = try v130Require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try JSONValue(jsonData: Data(contentsOf: url))
}
private func v130Matches(_ value: JSONValue, _ expected: JSONValue) throws -> Bool {
    let text = try value.jsonText()
    if let digest = expected["sha256"]?.stringValue {
        let bytes = Data(text.utf8)
        return bytes.count == expected["length"]?.intValue &&
            SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == digest
    }
    return try Array(text.utf8) == Array((expected.stringValue ?? expected.jsonText()).utf8)
}
private func v130Substitute(_ value: JSONValue, index: Int) -> JSONValue {
    if value["$index"]?.boolValue == true {
        return .number(Double(index * (value["scale"]?.intValue ?? 1) + (value["offset"]?.intValue ?? 0)))
    }
    switch value {
    case .array(let values): return .array(values.map { v130Substitute($0, index: index) })
    case .object(let object): return .object(JSONObject(object.map { ($0.key, v130Substitute($0.value, index: index)) }))
    default: return value
    }
}

@Suite struct FixtureV130Tests {
    @Test func trackerPlansMatchTag() throws {
        let fixture = try v130Fixture("tracker-v130-fixtures")
        let cases = try v130Require(fixture["cases"]?.arrayValue)
        #expect(cases.count == 4)
        for row in cases {
            let tracker = try Delta.track(v130Require(row["base"]))
            let change = tracker.beginChange()
            var prepared: Delta.Prepared?
            func perform(_ step: JSONValue) throws {
                if step["op"] == "repeat" {
                    for index in 0..<(step["count"]?.intValue ?? 0) {
                        try perform(v130Substitute(v130Require(step["step"]), index: (step["from"]?.intValue ?? 0) + index))
                    }
                    return
                }
                var draft = try change.state
                for part in step["path"]?.arrayValue ?? [] {
                    if let key = part.stringValue { draft = try v130Require(try draft.child(key)) }
                    else { draft = try v130Require(try draft.child(v130Require(part.intValue))) }
                }
                switch step["op"]?.stringValue {
                case "push": try draft.append(contentsOf: step["values"]?.arrayValue ?? [])
                case "shift": _ = try draft.popFirst()
                case "pop": _ = try draft.popLast()
                case "splice": try draft.splice(v130Require(step["start"]?.intValue), deleteCount: step["deleteCount"]?.intValue, insert: step["values"]?.arrayValue ?? [])
                case "reverse": try draft.reverse()
                case "set": try draft.set(v130Require(step["key"]?.stringValue), v130Require(step["value"]))
                case "prepare": prepared = try change.prepare()
                case "adopt": try tracker.adopt(v130Require(prepared))
                default: Issue.record("Unknown fixture step: \(step)")
                }
            }
            let steps = try v130Require(row["steps"]?.arrayValue)
            let events = try v130Require(row["events"]?.arrayValue)
            #expect(steps.count == events.count)
            for (step, event) in zip(steps, events) {
                // Adoption does not access the revoked draft.
                if step["op"] == "adopt" { try tracker.adopt(v130Require(prepared)) }
                else { try perform(step) }
                if let ops = event["ops"] {
                    #expect(try v130Matches(JSONValue(encoding: v130Require(prepared).ops), ops))
                    #expect(try Delta.applyImmutable(v130Require(prepared).base, v130Require(prepared).ops) == v130Require(prepared).value)
                }
                if let expected = event["valueText"] {
                    let value = step["op"] == "adopt" ? tracker.value : try v130Require(prepared).value
                    #expect(try v130Matches(value, expected))
                }
            }
        }
    }

    @Test func immutableAppendCasesMatchTag() throws {
        let fixture = try v130Fixture("delta-v130-fixtures")
        let rows = try v130Require(fixture["apply"]?.arrayValue)
        #expect(rows.count == 13)
        for row in rows {
            let base = try JSONValue(jsonText: v130Require(row["initialText"]?.stringValue))
            do {
                let ops = try v130Require(row["ops"]).decode([Delta.Op].self)
                let result = try v130Require(try Delta.applyImmutable(base, ops))
                #expect(row["errorKind"] == nil)
                #expect(try v130Matches(result, v130Require(row["resultText"])))
            } catch {
                #expect(row["errorKind"] != nil)
                #expect(String(describing: error) == row["errorText"]?.stringValue)
            }
            #expect(try base.jsonText() == row["initialText"]?.stringValue)
        }
    }
}
