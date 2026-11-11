import Foundation
import Testing
import PiSwiftAgent
@testable import PiSwiftCodingAgent

private func cextRunner(_ hooks: [LoadedHook]) -> HookRunner {
    HookRunner(hooks, FileManager.default.currentDirectoryPath, SessionManager.inMemory(),
               ModelRegistry(AuthStorage(":memory:")))
}

private func cextHook(_ api: HookAPI, path: String) -> LoadedHook {
    LoadedHook(path: path, resolvedPath: path, handlers: api.handlers,
               messageRenderers: api.messageRenderers,
               markdownTransformers: api.markdownTransformers,
               entryRenderers: api.entryRenderers)
}

@Test func cextRunsMarkdownTransformersOnlyOnTheirMessageTypes() {
    let first = HookAPI(hookPath: "default")
    first.registerMarkdownTransformer { markdown, _ in markdown + " default" }
    let second = HookAPI(hookPath: "opt-in")
    second.registerMarkdownTransformer({ markdown, _ in markdown + " opt-in" },
                                       options: .init(messageTypes: [.assistant, .changelog]))
    let runner = cextRunner([cextHook(first, path: "default"), cextHook(second, path: "opt-in")])
    #expect(runner.getMarkdownTransformers().count == 2)
    func apply(_ surface: MarkdownMessageType) -> String {
        runner.transformMarkdown("text", context: .init(messageType: surface, isStreaming: false,
                                                         availableWidth: 80))
    }
    #expect(apply(.user) == "text default")
    #expect(apply(.assistantThinking) == "text default")
    #expect(apply(.assistant) == "text default opt-in")
    #expect(apply(.changelog) == "text opt-in")
    #expect(apply(.custom) == "text")
    #expect(apply(.summary) == "text")
}

@Test func cextChainsMarkdownTransformersInRegistrationOrderAndPassesMetadata() {
    let api = HookAPI(hookPath: "metadata")
    api.registerMarkdownTransformer({ markdown, context in
        "\(context.messageId ?? "-"):\(context.timestamp ?? "-"):\(markdown)"
    }, options: .init(messageTypes: [.summary]))
    api.registerMarkdownTransformer({ markdown, _ in markdown + " done" },
                                    options: .init(messageTypes: [.summary]))
    let runner = cextRunner([cextHook(api, path: "metadata")])
    #expect(runner.transformMarkdown("text", context: .init(messageType: .summary,
        isStreaming: false, availableWidth: 78, messageId: "entry-1",
        timestamp: "2025-01-15T10:30:00.000Z")) == "entry-1:2025-01-15T10:30:00.000Z:text done")
    #expect(runner.transformMarkdown("text", context: .init(messageType: .summary,
        isStreaming: true, availableWidth: 78)) == "-:-:text done")
}

@Test func cextCustomBlockedStatusAndRendererHintsReachHost() {
    let options = HookCustomOptions(overlay: true,
        blocked: .init(kind: .question, message: "Choose a file"))
    #expect(options.overlay)
    #expect(options.blocked == .init(kind: .question, message: "Choose a file"))

    let hints = HookKeybindingHints(keyText: { key in key == "app.tools.expand" ? "ctrl+e" : "" },
                                    keyHint: { key, description in "\(key == "app.tools.expand" ? "ctrl+e" : "") \(description)" })
    let message = HookMessageRenderOptions(expanded: false, keybindingHints: hints)
    let entry = EntryRenderOptions(expanded: true, keybindingHints: hints)
    #expect(message.keyText("app.tools.expand") == "ctrl+e")
    #expect(message.keyHint("app.tools.expand", "to expand") == "ctrl+e to expand")
    #expect(entry.keyText("app.tools.expand") == "ctrl+e")
    #expect(entry.keyHint("app.tools.expand", "to expand") == "ctrl+e to expand")
    #expect(HookMessageRenderOptions(expanded: false).keyText("app.tools.expand").isEmpty)
}

// Ports extension-keybinding-hints.test.ts:29: both tool render slots receive the host's hints.
@Test func cextToolRenderersReceiveHostKeyTextAndHint() throws {
    let tool = CustomTool(
        name: "custom_tool", label: "custom_tool", description: "custom tool", parameters: [:],
        execute: { _, _, _, _, _ in AgentToolResult(content: []) },
        renderCallWithContext: { _, _, context in
            "\(context.keyText("app.tools.expand")) | \(context.keyHint("app.tools.expand", "to expand"))"
        },
        renderResultWithContext: { _, _, _, context in
            "\(context.keyText("app.tools.expand")) | \(context.keyHint("app.tools.expand", "to expand"))"
        }
    )
    let runner = cextRunner([])
    let renderers = try #require(runner.resolveToolRenderers("custom_tool") {
        CustomToolRenderers(tool: tool)
    })
    let host = HookToolRenderContext(keybindingHints: .init(
        keyText: { key in key == "app.tools.expand" ? "ctrl+e" : "" },
        keyHint: { key, description in key == "app.tools.expand" ? "ctrl+e \(description)" : "" }
    ))
    let expected = "ctrl+e | ctrl+e to expand"
    #expect(try renderers.renderCallWithContext?([:], .fallback(), host) as? String == expected)
    #expect(try renderers.renderResultWithContext?(
        AgentToolResult(content: []), RenderResultOptions(expanded: false, isPartial: false),
        .fallback(), host) as? String == expected)
    #expect(HookToolRenderContext().keyText("app.tools.expand").isEmpty)

    let definition = ToolDefinition(
        name: "custom_tool", label: "custom_tool", description: "custom tool",
        renderCallWithContext: { _, _, context in context.keyHint("app.tools.expand", "to expand") },
        renderResultWithContext: { _, _, _, context in context.keyHint("app.tools.expand", "to expand") }
    )
    #expect(definition.renderCallWithContext?([:], .fallback(), host) as? String == "ctrl+e to expand")
}
