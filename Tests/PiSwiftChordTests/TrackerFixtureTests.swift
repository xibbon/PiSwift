import CryptoKit
import Foundation
import Testing
import PiSwiftChord

private struct TrackerFixtures: Decodable {
    struct Case: Decodable {
        let name: String
        let category: String
        let base: JSONValue
        let steps: [Step]
        let events: [Event]
    }
    struct Step: Decodable {
        let op: String
        let change: String?
        let path: [JSONValue]?
        let handle: String?
        let key: JSONValue?
        let value: JSONValue?
        let values: [JSONValue]?
        let start: Int?
        let deleteCount: Int?
        let noArguments: Bool?
        let count: Int?
        let name: String?
        let step: JSONValue?
        let from: Int?
        let stride: Int?
    }
    struct Event: Decodable {
        let step: Int
        let error: String?
        let ops: JSONValue?
        let valueText: JSONValue?
        let baseRevision: Int?
        let revision: Int?
    }
    let cases: [Case]
}

private func fixtureRequired<T>(_ value: T?) throws -> T { try #require(value) }

// Small outputs compare their exact UTF-8 bytes. Large outputs compare the same
// bytes with SHA256 and their byte count. Array expectations contain op tuples.
private func trackerFixtureMatches(_ text: String, _ expected: JSONValue) throws -> Bool {
    let bytes = Data(text.utf8)
    if let digest = expected.objectValue {
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return bytes.count == digest["length"]?.intValue && hash == digest["sha256"]?.stringValue
    }
    let expectedText = try expected.stringValue ?? expected.jsonText()
    return bytes == Data(expectedText.utf8)
}

// Expand the same index markers that the Node oracle uses. This recursion
// follows a small fixture template, not the depth of a document path.
private func trackerFixtureSubstitute(_ value: JSONValue, index: Int) -> JSONValue {
    switch value {
    case .array(let values): return .array(values.map { trackerFixtureSubstitute($0, index: index) })
    case .object(let object):
        if object["$index"]?.boolValue == true {
            let number = index * (object["scale"]?.intValue ?? 1) + (object["offset"]?.intValue ?? 0)
            if let prefix = object["prefix"]?.stringValue { return .string(prefix + String(number)) }
            return .number(Double(number))
        }
        return .object(JSONObject(object.map { key, value in (key, trackerFixtureSubstitute(value, index: index)) }))
    default: return value
    }
}

@Suite struct TrackerFixtureTests {
    @Test func replaysUpstreamTrackerFixtures() throws {
        let url = try fixtureRequired(Bundle.module.url(forResource: "tracker-fixtures", withExtension: "json", subdirectory: "Fixtures"))
        let fixtures = try JSONValue(jsonData: Data(contentsOf: url)).decode(TrackerFixtures.self)
        #expect(fixtures.cases.count == 925)
        for entry in fixtures.cases {
            let tracker = try Delta.track(entry.base)
            var changes: [String: Delta.Change] = ["main": tracker.beginChange()]
            var prepared: [String: Delta.Prepared] = [:]
            var handles: [String: JSONDraft] = [:]
            #expect(entry.events.count == entry.steps.count, "case \(entry.name)")
            for (index, step) in entry.steps.enumerated() {
                let event = try fixtureRequired(entry.events.indices.contains(index) ? entry.events[index] : nil)
                #expect(event.step == index)
                let label = "case \(entry.name), step \(index), \(step.op)"
                var actualError: String?
                do {
                    switch step.op {
                    case "begin": changes[try fixtureRequired(step.name)] = tracker.beginChange()
                    case "prepare":
                        let change = try fixtureRequired(changes[step.change ?? "main"])
                        let result = try change.prepare()
                        prepared[try fixtureRequired(step.name)] = result
                        #expect(try trackerFixtureMatches(JSONValue.array(result.ops.map(\.json)).jsonText(), fixtureRequired(event.ops)), Comment(rawValue: label))
                        #expect(try trackerFixtureMatches(result.value.jsonText(), fixtureRequired(event.valueText)), Comment(rawValue: label))
                        #expect(result.baseRevision == event.baseRevision, Comment(rawValue: label))
                        #expect(try Delta.applyImmutable(result.base, result.ops) == result.value, Comment(rawValue: label))
                    case "replace":
                        let result = try tracker.prepareReplace(step.value ?? .null)
                        prepared[try fixtureRequired(step.name)] = result
                        #expect(try trackerFixtureMatches(JSONValue.array(result.ops.map(\.json)).jsonText(), fixtureRequired(event.ops)), Comment(rawValue: label))
                        #expect(try trackerFixtureMatches(result.value.jsonText(), fixtureRequired(event.valueText)), Comment(rawValue: label))
                        #expect(result.baseRevision == event.baseRevision, Comment(rawValue: label))
                    case "adopt":
                        try tracker.adopt(try fixtureRequired(prepared[try fixtureRequired(step.name)]))
                        #expect(try trackerFixtureMatches(tracker.value.jsonText(), fixtureRequired(event.valueText)), Comment(rawValue: label))
                        #expect(tracker.revision == event.revision, Comment(rawValue: label))
                    case "abort": try fixtureRequired(changes[step.change ?? "main"]).abort()
                    case "abortPrepared": try fixtureRequired(prepared[try fixtureRequired(step.name)]).abort()
                    case "repeat":
                        let template = try fixtureRequired(step.step)
                        for offset in 0..<(try fixtureRequired(step.count)) {
                            let expanded = trackerFixtureSubstitute(template, index: (step.from ?? 0) + offset * (step.stride ?? 1))
                            for value in expanded.arrayValue ?? [expanded] {
                                let item = try value.decode(TrackerFixtures.Step.self)
                                var target: JSONDraft
                                if let handle = item.handle { target = try fixtureRequired(handles[handle]) }
                                else { target = try fixtureRequired(changes[item.change ?? "main"]).state }
                                for segment in item.path ?? [] {
                                    if let key = segment.stringValue { target = try fixtureRequired(try target.child(key)) }
                                    else { target = try fixtureRequired(try target.child(try fixtureRequired(segment.intValue))) }
                                }
                                switch item.op {
                                case "set":
                                    if let key = item.key?.stringValue { try target.set(key, item.value ?? .null) }
                                    else { try target.set(try fixtureRequired(item.key?.intValue), item.value ?? .null) }
                                case "push": try target.append(contentsOf: item.values ?? [])
                                default: Issue.record("Unsupported repeat operation: \(item.op)")
                                }
                            }
                        }
                    default:
                        var target: JSONDraft
                        if let handle = step.handle { target = try fixtureRequired(handles[handle]) }
                        else { target = try fixtureRequired(changes[step.change ?? "main"]).state }
                        for segment in step.path ?? [] {
                            if let key = segment.stringValue { target = try fixtureRequired(try target.child(key)) }
                            else { target = try fixtureRequired(try target.child(try fixtureRequired(segment.intValue))) }
                        }
                        switch step.op {
                        case "set":
                            if let key = step.key?.stringValue { try target.set(key, step.value ?? .null) }
                            else { try target.set(try fixtureRequired(step.key?.intValue), step.value ?? .null) }
                        case "delete": try target.remove(try fixtureRequired(step.key?.stringValue))
                        case "addString":
                            let key = try fixtureRequired(step.key?.stringValue)
                            let old = try fixtureRequired(target.get(key)?.stringValue)
                            try target.set(key, .string(old + (try fixtureRequired(step.value?.stringValue))))
                        case "addNumber":
                            let key = try fixtureRequired(step.key?.stringValue)
                            let old = try fixtureRequired(target.get(key)?.numberValue)
                            try target.set(key, .number(old + (try fixtureRequired(step.value?.numberValue))))
                        case "push": try target.append(contentsOf: step.values ?? [])
                        case "pop": _ = try target.popLast()
                        case "shift": _ = try target.popFirst()
                        case "unshift": try target.prepend(contentsOf: step.values ?? [])
                        case "splice": _ = try target.splice(step.start ?? 0, deleteCount: step.noArguments == true ? 0 : step.deleteCount, insert: step.values ?? [])
                        case "reverse": try target.reverse()
                        case "length": try target.setCount(try fixtureRequired(step.count))
                        case "hold": handles[try fixtureRequired(step.name)] = target
                        case "snapshot":
                            let value = try target.snapshot()
                            #expect(try trackerFixtureMatches(value.jsonText(), fixtureRequired(event.valueText)), Comment(rawValue: label))
                        default: Issue.record("Unknown fixture operation: \(step.op)")
                        }
                    }
                } catch {
                    actualError = String(describing: error)
                    #expect(error is TrackerError, Comment(rawValue: label))
                }
                #expect(actualError == event.error, Comment(rawValue: label))
            }
        }
    }
}
