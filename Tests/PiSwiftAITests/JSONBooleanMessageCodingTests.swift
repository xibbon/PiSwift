import Foundation
import Testing
import PiSwiftAI

private func booleanMetadataObject(_ json: String) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
}

@Suite struct JSONBooleanMessageCodingTests {
    @Test func constrainedSamplingRequiresLiteralFalse() throws {
        for literal in ["0", "1", "false", "true"] {
            let object = try booleanMetadataObject("""
                {"role":"system","toolsAdded":[{"name":"tool","description":"test","parameters":{},"constrainedSampling":\(literal)}]}
                """)
            guard case .system(let message) = try #require(messageFromJSONObject(object)) else {
                Issue.record("Expected system message")
                return
            }
            let tool = try #require(message.toolsAdded?.first)
            if literal == "false" {
                guard case .disabled? = tool.constrainedSampling else {
                    Issue.record("Expected disabled sampling")
                    return
                }
            } else {
                #expect(tool.constrainedSampling == nil)
            }
        }
    }

    @Test func toolResultErrorRequiresBoolean() throws {
        for literal in ["0", "1", "false", "true"] {
            let object = try booleanMetadataObject("""
                {"role":"toolResult","isError":\(literal)}
                """)
            guard case .toolResult(let message) = try #require(messageFromJSONObject(object)) else {
                Issue.record("Expected tool result message")
                return
            }
            #expect(message.isError == (literal == "true"))
        }
    }

    @Test func thinkingRedactedRequiresBoolean() throws {
        for literal in ["0", "1", "false", "true"] {
            let object = try booleanMetadataObject("""
                {"type":"thinking","thinking":"test","redacted":\(literal)}
                """)
            guard case .thinking(let thinking) = try #require(contentBlockFromJSONObject(object)) else {
                Issue.record("Expected thinking content")
                return
            }
            let expected: Bool? = literal == "true" ? true : literal == "false" ? false : nil
            #expect(thinking.redacted == expected)
        }
    }

    @Test func assistantEndTurnRequiresBoolean() throws {
        for literal in ["0", "1", "false", "true"] {
            let object = try booleanMetadataObject("""
                {"endTurn":\(literal)}
                """)
            let message = assistantMessageFromJSONObject(object)
            let expected: Bool? = literal == "true" ? true : literal == "false" ? false : nil
            #expect(message.endTurn == expected)
        }
    }

    @Test func nestedCallsCompleteRequiresBoolean() throws {
        for literal in ["0", "1", "false", "true"] {
            let object = try booleanMetadataObject("""
                {"complete":\(literal),"calls":[]}
                """)
            let calls = nestedToolCallsFromJSONObject(object)
            let expected: Bool? = literal == "true" ? true : literal == "false" ? false : nil
            #expect(calls?.complete == expected)
        }
    }
}
