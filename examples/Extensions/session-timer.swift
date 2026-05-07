// session-timer.swift — Example PiSwift extension
//
// Tracks how long a session has been active and displays it in the
// status bar. Demonstrates:
// - Using actor-based state management (Sendable-safe)
// - Hooking into session_start and agent_end events
// - Using the status bar API
// - Registering a /timer command

import Foundation
import PiExtensionSDK

/// Thread-safe state for the timer.
private actor TimerState {
    var startDate: Date?

    func start() { startDate = Date() }

    func elapsed() -> String {
        guard let start = startDate else { return "not started" }
        let seconds = Int(Date().timeIntervalSince(start))
        let minutes = seconds / 60
        let secs = seconds % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}

private let state = TimerState()

@_cdecl("piExtensionMain")
public func piExtensionMain(_ raw: UnsafeMutableRawPointer) {
    withExtensionAPI(raw) { pi in

        // Start the timer when the session begins
        pi.on("session_start") { (event: SessionStartEvent, ctx: HookContext) in
            await state.start()
            await ctx.ui.setStatus("timer", "0:00")
            return nil
        }

        // Update the timer display after each agent turn
        pi.on("agent_end") { (event: AgentEndEvent, ctx: HookContext) in
            let elapsed = await state.elapsed()
            await ctx.ui.setStatus("timer", elapsed)
            return nil
        }

        // /timer command shows the elapsed time
        pi.registerCommand("timer", description: "Show session elapsed time") { args, ctx in
            let elapsed = await state.elapsed()
            await ctx.ui.notify("Session time: \(elapsed)", .info)
        }
    }
}
