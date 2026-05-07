// permission-gate.swift — Confirm before running dangerous bash commands.
//
// Drop into ~/.pi/agent/extensions/ and the agent will prompt before letting the LLM
// run `rm -rf`, `sudo`, or `chmod 777` style commands. Demonstrates:
//   - Intercepting tool_call events
//   - Returning a ToolCallEventResult to block / allow
//   - Falling back to "block by default" when there's no UI to prompt the user

import Foundation
import PiExtensionSDK

@_cdecl("piExtensionMain")
public func piExtensionMain(_ raw: UnsafeMutableRawPointer) {
    withExtensionAPI(raw) { pi in
        let dangerous: [NSRegularExpression] = [
            try? NSRegularExpression(pattern: #"\brm\s+(-rf?|--recursive)"#, options: .caseInsensitive),
            try? NSRegularExpression(pattern: #"\bsudo\b"#, options: .caseInsensitive),
            try? NSRegularExpression(pattern: #"\b(chmod|chown)\b.*777"#, options: .caseInsensitive),
        ].compactMap { $0 }

        pi.on("tool_call") { (event: ToolCallEvent, ctx: HookContext) -> Any? in
            guard event.toolName == "bash" else { return nil }
            guard let command = event.input["command"]?.jsonValue as? String else { return nil }

            let range = NSRange(command.startIndex..., in: command)
            let isDangerous = dangerous.contains { regex in
                regex.firstMatch(in: command, options: [], range: range) != nil
            }
            guard isDangerous else { return nil }

            if !ctx.hasUI {
                return ToolCallEventResult(block: true, reason: "Dangerous command blocked (no UI for confirmation)")
            }

            let allow = await ctx.ui.confirm(
                "Dangerous command",
                "About to run:\n\n  \(command)\n\nAllow?"
            )
            if !allow {
                return ToolCallEventResult(block: true, reason: "Blocked by user")
            }
            return nil
        }
    }
}
