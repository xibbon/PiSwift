import Foundation
import Synchronization
import Testing
@testable import PiSwiftAI

private func canonicalToolJSON(_ value: Any) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

@Test func taggedToolValidationVectors() throws {
    let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Resources/tool-validation-v1.5.2.jsonl")
    let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
    #expect(lines.count >= 301)
    for line in lines.dropFirst() {
        let row = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let id = try #require(row["id"] as? String)
        let schema = try #require(row["schema"] as? [String: Any])
        let args = try #require(row["arguments"] as? [String: Any])
        let name = try #require(row["name"] as? String)
        let tool = AITool(name: name, description: "", parameters: schema.mapValues(AnyCodable.init))
        let sourceText = try #require(row["argumentsJSON"] as? String)
        let source = row["withoutOrder"] as? Bool == true ? nil : try OrderedJSON.parse(sourceText)
        let call = ToolCall(id: id, name: name, arguments: args.mapValues(AnyCodable.init), argumentsJSON: source,
                            argumentsError: row["argumentsError"] as? String)
        do {
            let result = try validateToolArguments(tool: tool, toolCall: call)
            let expectedText = try #require(row["result"] as? String, "\(id): expected failure")
            let expected = try JSONSerialization.jsonObject(with: Data(expectedText.utf8), options: .fragmentsAllowed)
            #expect(try canonicalToolJSON(result.mapValues(\.value)) == canonicalToolJSON(expected), "\(id)")
        } catch {
            let expected = try #require((row["swiftExpectedError"] ?? row["error"]) as? String,
                                        "\(id): unexpected \(error)")
            #expect(error.localizedDescription == expected, "\(id)")
        }
    }
}

@Test func staleToolArgumentOrderUsesCurrentDictionary() throws {
    let schema: [String: Any] = ["type": "object", "properties": ["a": ["type": "number"], "z": ["type": "number"]]]
    let tool = AITool(name: "echo", description: "", parameters: schema.mapValues(AnyCodable.init))
    var call = ToolCall(id: "stale", name: "echo", arguments: ["z": AnyCodable("bad"), "a": AnyCodable("bad")],
                        argumentsJSON: try OrderedJSON.parse(#"{"z":"bad","a":"bad"}"#))
    call.arguments["a"] = AnyCodable("changed")
    do {
        _ = try validateToolArguments(tool: tool, toolCall: call)
        Issue.record("Expected validation failure")
    } catch {
        #expect(error.localizedDescription.contains("\"a\": \"changed\",\n  \"z\": \"bad\""))
    }
}

@Test func durableOrderedSchemaSourceKeepsTaggedErrorOrder() throws {
    // v1.5.2 D8: ai/src/utils/validation.ts:54-68 reports issues in schema property order.
    let schema: [String: Any] = ["type": "object", "properties": [
        "z": ["type": "number"], "a": ["type": "boolean"]
    ]]
    let tool = AITool(name: "echo", description: "", parameters: schema.mapValues(AnyCodable.init))
    let call = ToolCall(id: "ordered", name: "echo", arguments: ["z": AnyCodable("bad"), "a": AnyCodable("bad")],
        argumentsJSON: try OrderedJSON.parse(#"{"z":"bad","a":"bad"}"#))
    let source = try OrderedJSON.parse(#"{"type":"object","properties":{"z":{"type":"number"},"a":{"type":"boolean"}}}"#)
    do {
        _ = try validateToolArguments(tool: tool, toolCall: call, orderedParameters: source)
        Issue.record("Expected validation failure")
    } catch {
        let text = error.localizedDescription
        #expect(text.range(of: "- z: expected number")!.lowerBound < text.range(of: "- a: expected boolean")!.lowerBound)
    }
}

@Test func toolArgumentDepthLimitBecomesValidationFailure() throws {
    let outcome = Mutex(false)
    let done = DispatchSemaphore(value: 0)
    let worker = Thread {
        var nested: Any = NSNull()
        for _ in 0..<514 { nested = [nested] }
        let tool = AITool(name: "deep", description: "", parameters: [:])
        let call = ToolCall(id: "deep", name: "deep", arguments: ["value": AnyCodable(nested)])
        do { _ = try validateToolArguments(tool: tool, toolCall: call) }
        catch let error as ValidationError {
            if case .validationFailed(_, let issues, _) = error {
                outcome.withLock { $0 = issues.count == 1 && issues.first?.path == "root" &&
                    issues.first?.message == "value is nested too deeply" }
            }
        } catch { }
        done.signal()
    }
    worker.stackSize = 32 * 1024 * 1024
    worker.start()
    #expect(done.wait(timeout: .now() + 30) == .success)
    #expect(outcome.withLock { $0 })
}
