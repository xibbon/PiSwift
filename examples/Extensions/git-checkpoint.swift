// git-checkpoint.swift — Stash a checkpoint before each turn so /fork can restore code.
//
// Each turn, runs `git stash create` to snapshot the working tree (without modifying
// it). On session_before_fork, offers to apply the stash for the entry being forked
// from. Demonstrates:
//   - Async actor-based state for Sendable safety
//   - pi.exec() to shell out
//   - Reading session entries via ctx.sessionManager
//   - Hooking session_before_fork

import Foundation
import PiExtensionSDK

private actor Checkpoints {
    private var byEntryId: [String: String] = [:]
    private var lastEntryId: String?

    func record(entryId: String, ref: String) { byEntryId[entryId] = ref }
    func ref(for entryId: String) -> String? { byEntryId[entryId] }
    func setLastEntryId(_ id: String?) { lastEntryId = id }
    func getLastEntryId() -> String? { lastEntryId }
    func clear() { byEntryId.removeAll() }
}

private let state = Checkpoints()

@_cdecl("piExtensionMain")
public func piExtensionMain(_ raw: UnsafeMutableRawPointer) {
    withExtensionAPI(raw) { pi in

        // Track the most-recent entry id so we can attach the stash to it.
        pi.on("tool_result") { (_: ToolResultEvent, ctx: HookContext) -> Any? in
            if let leaf = ctx.sessionManager.getLeafEntry() {
                await state.setLastEntryId(leaf.id)
            }
            return nil
        }

        pi.on("turn_start") { (_: TurnStartEvent, _: HookContext) -> Any? in
            let result = await pi.exec("git", ["stash", "create"])
            let ref = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !ref.isEmpty, let entryId = await state.getLastEntryId() {
                await state.record(entryId: entryId, ref: ref)
            }
            return nil
        }

        pi.on("session_before_fork") { (event: SessionBeforeForkEvent, ctx: HookContext) -> Any? in
            guard let ref = await state.ref(for: event.entryId) else { return nil }
            guard ctx.hasUI else { return nil }

            let choice = await ctx.ui.select(
                "Restore code state?",
                ["Yes, restore code to that point", "No, keep current code"]
            )
            if choice?.hasPrefix("Yes") == true {
                _ = await pi.exec("git", ["stash", "apply", ref])
                await ctx.ui.notify("Code restored to checkpoint", .info)
            }
            return nil
        }

        pi.on("agent_end") { (_: AgentEndEvent, _: HookContext) -> Any? in
            await state.clear()
            return nil
        }
    }
}
