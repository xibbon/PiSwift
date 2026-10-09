# PiSwiftCodingAgentDurable

This module connects pi settings, models, and tools to `PiSwiftDurable`.
One process owns the model runtime, the durable Harness, SQLite storage, and the terminal UI.
The UI is in PiSwiftTui. This library has no terminal dependency.
The agent uses the Harness with its coding tools and `subagent` tool.

## Run

Use the pi command from PiSwiftTui:

```sh
pi durable
pi durable --continue
```

`pi durable -c` also continues a session. The subcommand is hidden from root help.
From the PiSwiftTui source directory, use `swift run pi-coding-agent durable`.
A new session uses the default model and thinking level from `settings.json`.
`--continue` opens the newest session for the current directory.
Log in with pi. The durable session uses the same credentials.

Sessions use `<agent-directory>/experimental/durable-sessions-swift/<cwd-hash>/<session>/session.sqlite`.
On macOS, the default agent directory is `~/.pi/agent`.
On iOS, it is the app's Application Support `agent` directory.
`PI_CODING_AGENT_DIR` overrides the agent directory.
Swift sessions are separate from TypeScript sessions. Do not share their databases.
Each open session holds an exclusive `flock` on `session.lock`.
A second open retries for up to two seconds. The kernel releases the lock when the process dies.

## What it shows

- **Durability:** the Harness commits streamed partials, tool output, queues, and turns.
  Continue after a process stops during a tool call. Recovery records an interrupted result and completes the turn.
  The UI only shows the view. It does not perform recovery.
- **One view:** the transcript and `pi.live`, `pi.inbox`, `pi.agent`, and `pi.usage` documents supply the display.
  The view includes streaming, tool progress, queues, retries, compaction, model selection, and usage.
- **Subagents:** the `subagent` tool creates a child conversation owned by its call.
  `/agents` changes the shown conversation. The editor then sends input to that conversation.
  You can steer a busy child or send more input after its task finishes.
  Aborting the main turn also aborts its subagents.
- **Task graph:** the live panel shows tasks, their dependencies, and the conversations they own.
  It starts open. `/tasks` hides or shows it.

## Commands and keys

These are the default Swift key names shown by `keyText`. Configured bindings can change them.

| Command or key | Action |
| --- | --- |
| Submit | Send a prompt when idle. Steer when busy. |
| `alt+enter` | Queue follow-up input. |
| `escape` | Abort work in the shown conversation, including manual compaction. |
| `/model` or `ctrl+l` | Select a model for the shown conversation. |
| `shift+tab` | Cycle supported thinking levels. |
| `/compact [instructions]` | Summarize older context. Show "Nothing to compact" if context fits in `compaction.keepRecentTokens`. |
| `/agents` | Select a conversation. |
| `/tasks` | Hide or show the task panel. |
| `ctrl+o` | Expand tool output and compaction summaries. |
| `ctrl+c` in the editor | Exit at once. Continue saved work with `--continue`. |
| `ctrl+d` in an empty editor | Exit. With a draft, use the editor's deletion behavior. |

In a selector, `ctrl+c` cancels the selector. It does not exit the application.
Compaction thresholds, retry policy, queue modes, and request timeouts use the loaded pi settings.
Harness settings read current manager values at each use. Call `SettingsManager.reload()` after a file change.
A submitted turn with no answer shows a notice. A recovered turn does not get this notice.

## Layout

| Swift file | Role |
| --- | --- |
| `Runtime.swift` | Open, control, and close the Harness. |
| `RuntimeViewSource.swift` | Store view snapshots and report changes. |
| `DurableView.swift` | Public view, controller, notices, and open options. |
| `Sessions.swift` | Session directories and locks. |
| `HarnessSettings.swift` | Read pi settings for the Harness. |
| `RegistryDurableModels.swift` | Use model registry routing and credentials. |
| `InitialAgentModel.swift` | Select the model for a new conversation. |
| `ExecutionEnvs.swift` | Share local environments by working directory. |
| `CodingRegistry.swift` | Install coding tools and the pi prompt. |
| `PiPrompt.swift` | Build tools, rules, docs, AGENTS.md, skills, and cwd sections. |
| `Subagent.swift` | Install the foreground subagent tool. |
| PiSwiftTui `DurableSubcommand.swift` | Parse arguments, open, run, and close. |
| PiSwiftTui `Modes/Durable/` | Render the view and send commands. |

## Embed in a host

Configure the agent directory, credentials, and model before opening a session.
This example is copied from `PublicOpenDurableTests.swift`. Its test uses a model with no network calls.
The ten-second wait is an example limit for that test. Choose a suitable limit for your host.

```swift
import Foundation
import PiSwiftCodingAgentDurable

private func embeddedSession(cwd: String) async throws -> DurableView {
    let session = try await openDurable(.init(cwd: cwd))
    do {
        await session.controller.submit("Give the saved answer.", whenBusy: .steer)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !session.view.current().conversation.entries.contains(where: { $0.kind == "pi.assistant" }) {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(10))
        }
        let view = session.view.current()
        await session.close()
        return view
    } catch {
        await session.close()
        throw error
    }
}
```

For a UI, subscribe to `session.view`, then read `current()` after each change.
Listeners run on a private serial queue. Transfer UI updates to the main actor.
Call `cancel()` on each subscription. Call `await session.close()` when the host finishes.
Closing preserves pending work for a later continue. It does not abort that work.
To continue from a host, pass `.init(cwd: cwd, continueSession: true)` to `openDurable`.

iOS supports the local file tools. It has no local shell. Local `bash` returns `shellUnavailable`.
`openDurable` always uses local environments and includes `bash`. It has no environment override.
For a remote `ExecutionEnv`, build a Harness with the public settings, model, prompt, and subagent helpers.
Set `HarnessOptions.env` to your remote factory.
To leave `bash` out, install `createReadTool()`, `createWriteTool()`, and `createEditTool()` in your registry.
Use `createPiPrompt` for that registry. `createCodingRegistry` includes `bash`.

## Accepted differences from upstream

- Swift has a separate session root and a kernel lock. It needs no ten-second stale-lock check.
- View listeners use a private serial queue. A UI host must transfer work to its main actor.
- HTTP timeouts apply to each request. There is no shared undici dispatcher or `httpProxy` setting.
- The terminal entry is a hidden `pi durable` subcommand. ArgumentParser supplies help and error text.
- The prompt keeps the accepted Codemode docs reference. Its build cache holds 128 entries.
- Model availability uses a cached registry snapshot. Opening does not refresh catalogs over the network.
- Default model lookup uses Swift resolver rules. Invalid thinking and queue strings use defaults.
- Deferred requests use PiSwiftAI API providers. Request options have no header-transform callback.
- Native failures use Swift error text. The task panel sorts task IDs numerically.
- Controller and close failures appear as notices. Close still cleans resources and releases the lock.
- Swift decodes built-in documents. Invalid agent data produces an empty agent state.
- `ctrl+d` requires an empty editor to exit. `ctrl+c` cancels a selector when it has focus.

Not here: session list and resume picker, forks and tree navigation, extensions, prompt templates, images, `/login`.
