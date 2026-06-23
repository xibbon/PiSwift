import PiSwiftAI
import PiSwiftAgent

public func makeHookRunnerBeforeToolCallHook(_ hookRunner: HookRunner) -> BeforeToolCallFn {
    { context, _ in
        guard hookRunner.hasHandlers("tool_call") else { return nil }
        let event = ToolCallEvent(
            toolName: context.toolCall.name,
            toolCallId: context.toolCall.id,
            input: context.args
        )
        if let result = await hookRunner.emitToolCall(event), result.block {
            return BeforeToolCallResult(block: true, reason: result.reason)
        }
        return nil
    }
}

public func makeHookRunnerAfterToolCallHook(_ hookRunner: HookRunner) -> AfterToolCallFn {
    { context, _ in
        guard hookRunner.hasHandlers("tool_result") else { return nil }
        let event = ToolResultEvent(
            toolName: context.toolCall.name,
            toolCallId: context.toolCall.id,
            input: context.args,
            content: context.result.content,
            details: context.result.details,
            isError: context.isError
        )
        guard let result = await hookRunner.emit(event) as? ToolResultEventResult else {
            return nil
        }
        return AfterToolCallResult(
            content: result.content,
            details: result.details,
            isError: result.isError
        )
    }
}
