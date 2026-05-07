// protected-paths.swift — Block writes/edits to sensitive paths.
//
// Useful for preventing accidental clobbering of `.env`, `.git/`, `node_modules/`, etc.
// Demonstrates: simple substring matching against a tool input parameter.

import PiExtensionSDK

@_cdecl("piExtensionMain")
public func piExtensionMain(_ raw: UnsafeMutableRawPointer) {
    withExtensionAPI(raw) { pi in
        let protectedPaths = [".env", ".git/", "node_modules/"]

        pi.on("tool_call") { (event: ToolCallEvent, ctx: HookContext) -> Any? in
            guard event.toolName == "write" || event.toolName == "edit" else { return nil }
            guard let path = event.input["path"]?.jsonValue as? String else { return nil }

            guard let match = protectedPaths.first(where: { path.contains($0) }) else { return nil }

            if ctx.hasUI {
                await ctx.ui.notify("Blocked write to protected path: \(path)", .warning)
            }
            return ToolCallEventResult(block: true, reason: "Path \"\(path)\" is protected (matched \(match))")
        }
    }
}
