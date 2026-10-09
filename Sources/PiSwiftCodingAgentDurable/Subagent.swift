import PiSwiftAI
import PiSwiftChord
import PiSwiftDurable

private struct SubagentInput: Decodable, Sendable {
    let task: String
}

/// Creates a foreground subagent tool. The tool task owns its child conversation.
public func subagentExtension() throws -> Extension {
    let tool = try defineTool(
        name: "subagent",
        description: "Delegate a self-contained task to a subagent with the same tools and get its answer back. Give it everything it needs to know; it does not see this conversation.",
        parameters: [
            "type": .string("object"),
            "properties": .object([
                "task": .object([
                    "description": .string("What the subagent should do"),
                    "type": .string("string"),
                ]),
            ]),
            "required": .array([.string("task")]),
        ],
        args: SubagentInput.self,
        replay: .safe
    ) { args, api, context in
        let child = try await api.commit({ tx in
            if let existing = try await tx.scanConversations(.init(ownerTaskId: api.taskId), limit: 1).items.first {
                return existing.id
            }
            let created = try await tx.createConversation(ownership: .task(taskId: api.taskId))
            try await configure(tx: tx, conversationId: created.id,
                change: AgentChange(extensions: .set(.edit(remove: [Extension(name: "subagent")]))))
            return created.id
        }, context: context)
        let details: JSONValue = .object(["conversationId": .number(Double(child.rawValue))])
        try await api.details(details, context)
        guard let handle = try await api.conversation(id: child, context: context) else {
            throw SessionError.message("Conversation \(child.rawValue) does not exist")
        }
        let submission = try await handle.submit(
            .input(content: .text(args.task), requestId: "subagent:\(api.taskId.rawValue)"), context: context)
        let settled = try await submission.wait(context: context)
        guard settled.status == "done", settled.record.type == "input", let answer = settled.answer else {
            throw SessionError.message("Subagent \(child.rawValue) failed: \(settled.status)")
        }
        let text = try await subagentAnswerText(api: api, answer: answer, context: context)
        return ToolExecutionResult(content: [.text(TextContent(text: text))], details: details)
    }
    return Extension(name: "subagent", tools: [tool])
}

private func subagentAnswerText(api: ToolExecutionApi, answer: EntryID, context: ChordContext) async throws -> String {
    let entry = try await api.commit({ tx in try await tx.entry(assistantEntry, id: answer) }, context: context)
    guard case .assistant(let message) = try entry?.record.messages()?.first else { return "" }
    return message.content.compactMap { content in
        if case .text(let text) = content { return text.text }
        return nil
    }.joined()
}
