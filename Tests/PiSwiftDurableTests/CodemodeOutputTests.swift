import Foundation
import Synchronization
import PiSwiftAI
import PiSwiftChord
@testable import PiSwiftDurable
import PiSwiftDurableTesting
import Testing

@Suite(.timeLimit(.minutes(1)))
struct CodemodeOutputTests {
    @Test func wallTimeUsesJavaScriptTieRounding() async {
        for (milliseconds, expected) in [(50.0, "0.1"), (150.0, "0.1"), (350.0, "0.3"), (1150.0, "1.1"), (1250.0, "1.3"), (1350.0, "1.4"), (1750.0, "1.8"), (-1250.0, "-1.3"), (-0.0, "0.0"), (1e18 + 256, "1000000000000000.3"), (1e24, "1e+21")] {
            let formatted = await codemodeFormatResult(.init(), generatedImages: 0, wallMs: milliseconds, maxOutputTokens: 10, calls: []) { _, _ in .error("unused") }
            if case .text(let header) = formatted.content[0] { #expect(header.text.contains("Wall time \(expected) seconds")) }
            else { Issue.record("Missing script header") }
        }
    }
    @Test func textConsoleAndReturnLayout() async throws {
        let message = try await e10Run(DeterministicCodemodeSandbox { _ in
            .init(result: .init(value: "three", output: [.text("one"), .text("log 1", console: true), .text("{\"two\":2}")]))
        })
        let text = e10Text(message)
        #expect(text.hasPrefix("Script completed\nWall time "))
        #expect(text.contains(" seconds\nOutput:\n"))
        #expect(text.contains("==> text 1/3 <==\none\n==> text 2/3 <==\n{\"two\":2}\n==> text 3/3 <==\nthree"))
        #expect(text.contains("<console_output>\nlog 1\n</console_output>"))
    }
    @Test func tokenBudgetSpillsHeadAndTail() async throws {
        let full = "BEGIN" + String(repeating: "x", count: 1000) + "END", env = FakeExecutionEnv()
        let message = try await e10Run(DeterministicCodemodeSandbox { _ in .init(result: .init(output: [.text(full)])) }, code: "// @options: {\"max_output_tokens\":20}\nreturn 1", env: env)
        let text = e10Text(message), path = try #require(message["details"]?["fullOutputPath"]?.stringValue)
        #expect(text.contains("Warning: truncated output"))
        #expect(text.contains("BEGIN")); #expect(text.contains("END"))
        #expect(text.contains("[Full output: \(path)"))
        #expect(try await env.readTextFile(path, context: .background).get() == full)
    }
    @Test func byteAndLineLimitsSpillWithinHarnessLimits() async throws {
        for full in [String(repeating: "x", count: 6 * 1024 * 1024), Array(repeating: "a", count: 200_000).joined(separator: "\n")] {
            let env = FakeExecutionEnv()
            let message = try await e10Run(DeterministicCodemodeSandbox { _ in .init(result: .init(value: .string(full))) }, code: "// @options: {\"max_output_tokens\":2000000}\nreturn 1", env: env)
            let text = e10Text(message), path = try #require(message["details"]?["fullOutputPath"]?.stringValue)
            #expect(text.contains("Warning: truncated output"))
            #expect(text.utf16.count <= 1024 * 1024 + 1000)
            #expect(text.components(separatedBy: "\n").count < 100_000)
            #expect(try await env.readTextFile(path, context: .background).get() == full)
        }
    }
    @Test func savesImagesWithAdjacentPathsAndDeduplicatesBytes() async throws {
        let env = FakeExecutionEnv()
        let message = try await e10Run(DeterministicCodemodeSandbox { _ in .init(result: .init(output: [.image(data: e10PNG, mimeType: "image/png"), .image(data: e10PNG, mimeType: "image/png")])) }, env: env)
        let items = try #require(message["content"]?.arrayValue)
        let imageIndexes = items.indices.filter { items[$0]["type"] == "image" }
        #expect(imageIndexes.count == 2)
        for index in imageIndexes {
            let label = try #require(items[index - 1]["text"]?.stringValue)
            #expect(label.contains("[Image saved to "))
            let path = try #require(label.components(separatedBy: "[Image saved to ").last?.components(separatedBy: " (").first)
            #expect(Data(try await env.readBinaryFile(path, context: .background).get()).base64EncodedString() == e10PNG)
        }
        let firstLabel = try #require(items[imageIndexes[0] - 1]["text"]?.stringValue)
        #expect(firstLabel.contains("image-1.png"))
        #expect(!e10Text(message).contains("image-2.png"))
    }
    @Test func deferredToolRemainsCallableAndInCatalog() async throws {
        let message = try await e10Run(DeterministicCodemodeSandbox { state in
            if state.seq == 0 {
                #expect(state.options.tools.contains { $0.name == "later" })
                return .init(calls: [.init(name: "later", args: [:])])
            }
            return .init(result: .init(value: [e10Value(state.deliveries[0].outcome) ?? .null, true]))
        }, tools: [e10Tool("later", description: "A deferred tool", deferred: true) { _, _, _ in .init(output: [.text(.init(text: "later ran"))]) }])
        #expect(e10Text(message).contains("[\"later ran\",true]"))
    }
    @Test func nullToolArgumentsUseAnEmptyObject() async throws {
        let calls = Mutex(0)
        let message = try await e10Run(DeterministicCodemodeSandbox { state in
            if state.seq == 0 { return .init(calls: [.init(name: "echo", args: .null)]) }
            return .init(result: .init(value: e10Value(state.deliveries[0].outcome)))
        }, tools: [e10Tool("echo") { args, _, _ in
            #expect(args == .object([:]))
            calls.withLock { $0 += 1 }
            return .init(output: [.text(.init(text: "ok"))])
        }])
        #expect(calls.withLock { $0 } == 1)
        #expect(e10Text(message).hasSuffix("ok"))
        #expect(message["details"]?["calls"]?[0]?["status"] == "ok")
    }
    @Test func invalidToolArgumentsRejectWithoutRunningTool() async throws {
        let calls = Mutex(0)
        let message = try await e10Run(DeterministicCodemodeSandbox { state in
            if state.seq == 0 { return .init(calls: [.init(name: "echo", args: [1, 2])]) }
            guard case .failure(let message, _) = state.deliveries[0].outcome else {
                Issue.record("Invalid arguments resolved"); return .init(result: .init())
            }
            return .init(result: .init(value: .string(message)))
        }, tools: [e10Tool("echo") { _, _, _ in calls.withLock { $0 += 1 }; return .init(output: []) }])
        #expect(calls.withLock { $0 } == 0)
        #expect(e10Text(message).contains("Arguments of tool echo must be an object"))
        #expect(message["details"]?["calls"]?[0]?["status"] == "error")
    }
    @Test func failureShowsPriorCalls() async throws {
        let message = try await e10Run(DeterministicCodemodeSandbox { state in
            state.seq == 0 ? .init(calls: [.init(name: "echo", args: [:])]) : .init(result: .init(error: .init(kind: .script, message: "boom")))
        }, tools: [e10Tool("echo") { _, _, _ in .init(output: [.text(.init(text: "a"))]) }])
        #expect(message["isError"] == true)
        #expect(e10Text(message).hasPrefix("Script failed\n"))
        #expect(e10Text(message).contains("Error: boom"))
        #expect(e10Text(message).contains("Tool calls made before the failure (they are not undone): echo (ok)"))
    }
    @Test func discoveryUsesTheSavedCatalog() async throws {
        let message = try await e10Run(DeterministicCodemodeSandbox { state in
            if state.seq == 0 {
                #expect(state.options.tools.contains { $0.name == "mcp__github__list_issues" })
                return .init(calls: [.init(target: .global, name: "searchTools", args: ["issues"]),
                    .init(target: .global, name: "searchTools", args: ["echo", ["namespace": "github"]]),
                    .init(target: .global, name: "describeTool", args: ["echo"]),
                    .init(target: .global, name: "describeTool", args: ["nope"]),
                    .init(target: .global, name: "describeNamespace", args: ["github"])])
            }
            guard state.deliveries.count == 5 else { return .init() }
            let values = Dictionary(uniqueKeysWithValues: state.deliveries.map { ($0.id, e10Value($0.outcome) ?? .null) })
            return .init(result: .init(value: ["found": .array(values[1]?.arrayValue?.compactMap { $0["name"] } ?? []),
                "inNamespace": values[2] ?? .null, "described": .bool(values[3]?.stringValue?.contains("echo(args:") == true),
                "missing": values[4] ?? .null, "namespace": values[5] ?? .null]))
        }, tools: [e10Tool("echo"), e10Tool("mcp__github__list_issues")], namespaces: [.init(name: "github", prefix: "mcp__github__", description: "GitHub MCP server")])
        let output = try #require(message["content"]?[1]?["text"]?.stringValue)
        let value = try JSONValue(jsonText: output)
        #expect(value["found"] == ["mcp__github__list_issues"])
        #expect(value["inNamespace"] == [])
        #expect(value["described"] == true)
        #expect(value["missing"] == .null)
        #expect(value["namespace"] == ["name": "github", "description": "GitHub MCP server", "tools": ["mcp__github__list_issues"]])
    }
    @Test func fileFailuresStayVisibleAndManyTextItemsJoinLinearly() async {
        let result = CodemodeResult(output: (0..<20_000).map { .text(String($0)) } + [.image(data: e10PNG, mimeType: "image/png")])
        let formatted = await codemodeFormatResult(result, generatedImages: 0, wallMs: 0, maxOutputTokens: 10, calls: []) { _, _ in .error("disk full") }
        let text = formatted.content.compactMap { if case .text(let text) = $0 { text.text } else { nil } }.joined()
        #expect(text.contains("Could not save the full output: disk full"))
        #expect(text.contains("could not be saved: disk full"))
        #expect(formatted.content.contains { if case .image = $0 { true } else { false } })
        let joined = codemodeJoinText([.text(.init(text: "a")), .text(.init(text: "")), .text(.init(text: "b\n")), .text(.init(text: "c"))])
        if case .text(let text) = joined[0] { #expect(text.text == "a\nb\nc") }
        else { Issue.record("Text join did not return text") }
    }
}
