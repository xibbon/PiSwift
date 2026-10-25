# PiSwiftCodingAgentDurable

This module connects pi settings, models, and tools to `PiSwiftDurable`.
One process owns the model runtime, the durable Harness, SQLite storage, and the terminal UI.
The UI is in PiSwiftTui. This library has no terminal dependency.
The agent uses the Harness with its coding tools, `codemode`, and `subagent`.
Swift keeps this host after upstream removed its experimental durable host.
The hidden command and private session directory remain part of the Swift scope.

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
The library still reads and writes compatible SQLite and JSONL files.
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
| `CodemodeModels.swift` | Use the same registry for the catalog, classifiers, and images. |
| `InitialAgentModel.swift` | Select the model for a new conversation. |
| `ExecutionEnvs.swift` | Share local environments by working directory. |
| `CodingRegistry.swift` | Install coding tools, codemode, the pi prompt, and optional tool search. |
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

A backend failure stops command admission and closes the runtime automatically.
The final view has `terminal` set to `.closed` or `.failed(message:)`.
A failure also adds an error notice with the first cause.
View listeners receive the final snapshot on the same private serial queue.
Use `await session.closed` to wait for the final `SessionCloseResult` and cleanup.
The wait returns after environments are clean and the session lock is released.
`session.failure` gives the first backend error, if one occurred.
An explicit close and an automatic close share one cleanup operation.

Use `decodeAgentOf` and `decodeLiveOf` to read built-in view documents.
These functions throw on invalid data. Show the error instead of an empty state.
Live state includes nested tools and the last compaction failure.
Application input entries retain their kind, data, and user model contribution.
Conversation titles use the first user contribution from a built-in or application input.

iOS supports the local file tools. It has no local shell. Local `bash` returns `shellUnavailable`.
`openDurable` always uses local environments and includes `bash`. It has no environment override.
For a remote `ExecutionEnv`, build a Harness with the public settings, model, prompt, and subagent helpers.
Set `HarnessOptions.env` to your remote factory.
To leave `bash` out, install `createReadTool()`, `createWriteTool()`, and `createEditTool()` in your registry.
Use `createPiPrompt` for that registry. `createCodingRegistry` includes `bash`.

The stock host installs `createCodingTools(images: NativeImageProcessor())`.
Image reads can convert and resize files for the selected model. The native processor uses
ImageIO and CoreGraphics; encoded bytes and resampling can differ from upstream Photon.
This does not add image input to the terminal UI. Local environments have no native
`listFiles` implementation and return `notSupported`.

## Code mode and tool search

Both coding registry factories install durable `codemode` with `JSCCodemodeSandbox`.
The runtime owns one sandbox for each open session. It closes the Harness and its
invocations, then the sandbox, then the execution environments. A continued session
uses a new sandbox and the saved script journal. Finished nested calls use their saved
results. An interrupted unsafe tool, such as `bash`, can return an interrupted error.
Scripts can catch this error. The engine fingerprint must match to resume a script.
An OS or engine change can prevent resume. JavaScriptCore has no per-context heap cap.
On iOS, the watchdog can end a run before its JavaScript thread stops.

The model can call `codemode`. The classifier and image helper tools permit nested
tool calls only. Coding tools permit both caller types. Deferred tools remain callable
from scripts. Explicit extension and tool selections must include the required
extensions and tools; codemode does not bypass these filters.

`models.getModelsOfType`, `models.getAvailableOfType`, `models.getModelOfType`,
`models.classify`, and `models.generateImages` use `RegistryCodemodeModels`.
The runtime uses the same registry and credentials for these calls and for chat.
Credentials are resolved for each request. Catalog results omit credential headers.
Classifier and image requests receive the script's cancellation signal. Missing
credentials return the registry's error text. The session's `ExecutionEnv` writes
full text output and image files. The result includes their paths.

Set `durableDeferredTools` in `settings.json` to defer registered tools:

```json
{
  "durableDeferredTools": ["bash", "edit"]
}
```

This is a top-level setting because there was no nested durable settings object.
The default is `[]`. An empty list keeps the coding tools available and does not
install `tool_search`. A non-empty list installs the `tool-search` extension.
Named tools have `deferred: true`. Search loads matches with `modelTools.add` for
later model requests. An unknown name is reported once per registry and ignored.
The runtime shows the report as a warning. Custom registry hosts can receive it
through `onReport`. A project list replaces the global list; `[]` clears it.
The registry reads the list when it is created. Reopen the session to apply a change.
When you supply an explicit extension selection, include `codemode` and, if the list
is non-empty, `tool-search`.

Custom Harness hosts must supply `RegistryCodemodeModels` to enable model globals.
When you pass your own sandbox to `createCodingRegistry`, close the Harness before
you call `await sandbox.close()`. Keep the session's execution environment installed
for output and image files. PiSwiftTui's codemode display is separate work (H1t).

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
- Swift decodes built-in documents. The compatibility helper `agentOf` returns an empty state on invalid data; `decodeAgentOf` reports the error.
- `ctrl+d` requires an empty editor to exit. `ctrl+c` cancels a selector when it has focus.

Not here: session list and resume picker, forks and tree navigation, extensions, prompt templates, image input in the terminal UI, `/login`.
