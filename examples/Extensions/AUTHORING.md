# Writing PiSwift extensions

Extensions are single Swift files (or SPM packages) that PiSwift compiles and
`dlopen`s at startup. They plug into the agent's lifecycle: respond to events,
register slash commands, intercept tool calls, render custom UI.

## Where to put them

| Location | Scope |
| --- | --- |
| `~/.pi/agent/extensions/<name>.swift` | global, all projects |
| `~/.pi/agent/extensions/<name>/Package.swift` | global SPM package |
| `<cwd>/.pi/extensions/<name>.swift` | project-local |

After editing or adding an extension, run `/reload` from the TUI — PiSwift
compiles the new source, `dlopen`s the dylib, fires `session_shutdown(reason:
.reload)` to the previous instance, swaps it in, and fires
`session_start(reason: .reload)` to the new instance.

## Minimal template

```swift
import PiExtensionSDK

@_cdecl("piExtensionMain")
public func piExtensionMain(_ raw: UnsafeMutableRawPointer) {
    withExtensionAPI(raw) { pi in

        // React to lifecycle events.
        pi.on("session_start") { (event: SessionStartEvent, ctx: HookContext) in
            await ctx.ui.notify("Hello from my extension!", .info)
            return nil
        }

        // Register a slash command.
        pi.registerCommand("hello", description: "Greet someone") { args, ctx in
            let name = args.trimmingCharacters(in: .whitespaces)
            await ctx.ui.notify("Hello, \(name.isEmpty ? "world" : name)!", .info)
        }

        // Register a keyboard shortcut.
        pi.registerShortcut(.init("shift+g"), description: "Quick greet") { ctx in
            await ctx.ui.notify("Greeted via shortcut!", .info)
        }
    }
}
```

The `@_cdecl("piExtensionMain")` annotation exports the entry point as a C
symbol so PiSwift can find it via `dlsym`. `withExtensionAPI(raw) { pi in ... }`
unwraps the opaque API pointer into a typed `HookAPI`.

## What `pi` (HookAPI) gives you

| Method | Purpose |
| --- | --- |
| `pi.on(eventName) { event, ctx in ... }` | Subscribe to a lifecycle event |
| `pi.registerCommand(name, description:) { args, ctx in ... }` | Add a `/<name>` slash command |
| `pi.registerShortcut(KeyId, description:) { ctx in ... }` | Add a keyboard shortcut |
| `pi.registerMessageRenderer(customType) { msg, opts, theme in ... }` | Custom rendering for hook messages |
| `pi.registerFlag(name, options)` / `pi.getFlag(name)` | Persisted boolean/string flags |
| `pi.sendMessage(input, options:)` | Inject a message into the conversation |
| `pi.appendEntry(customType, data)` | Persist a custom entry to the session log |
| `pi.setSessionName(name)` / `pi.getSessionName()` | Read / set the session label |
| `pi.getActiveTools()` / `pi.getAllTools()` / `pi.setActiveTools([names])` | Tool roster control |
| `pi.exec(cmd, args, options:)` | Shell out without spawning a tool call |

## What `ctx.ui` gives you

`ctx.ui` is `@MainActor`-isolated, so call its methods from inside an `await`
expression. The TUI provides real implementations; in non-interactive mode
(`!ctx.hasUI`) the calls become no-ops and `confirm`/`select`/`input` return
`nil`/`false` — guard with `ctx.hasUI` when you need a user response.

| Method | Purpose |
| --- | --- |
| `ctx.ui.notify(text, .info\|.warning\|.error)` | Toast notification |
| `ctx.ui.confirm(title, message)` → `Bool` | Yes/no prompt |
| `ctx.ui.select(title, [options])` → `String?` | List selection |
| `ctx.ui.input(title, placeholder)` → `String?` | Single-line input |
| `ctx.ui.editor(title, prefill)` → `String?` | Multi-line editor |
| `ctx.ui.setStatus(key, text?)` | Footer status entry |
| `ctx.ui.setWidget(key, lines\|component)` | Widget above the editor |
| `ctx.ui.setFooter(factory?)` | Custom footer component |
| `ctx.ui.setTitle(text)` | Terminal/window title |
| `ctx.ui.setEditorText(text)` / `getEditorText()` | Editor contents |

## Common events

| Event | Type | When |
| --- | --- | --- |
| `session_start` | `SessionStartEvent` | Session loaded — `event.reason` ∈ {.startup, .reload, .new, .resume, .fork} |
| `session_shutdown` | `SessionShutdownEvent` | Session ending — clean up widgets/timers/files |
| `tool_call` | `ToolCallEvent` | Before a tool runs. Return `ToolCallEventResult(block: true, reason: ...)` to deny. |
| `tool_result` | `ToolResultEvent` | After a tool returns. Return `ToolResultEventResult` to rewrite content/details. |
| `before_agent_start` | `BeforeAgentStartEvent` | After user prompt arrives, before LLM call |
| `agent_start` / `agent_end` | `AgentStartEvent` / `AgentEndEvent` | LLM call boundaries |
| `turn_start` / `turn_end` | `TurnStartEvent` / `TurnEndEvent` | Each agent turn (tool-call loop iteration) |
| `model_select` | `ModelSelectEvent` | User changed the model |
| `before_provider_request` | `BeforeProviderRequestEvent` | About to POST to provider — payload as JSON string |
| `after_provider_response` | `AfterProviderResponseEvent` | HTTP response received, before stream consume |
| `session_before_compact` / `session_compact` | events | Compaction lifecycle |
| `session_before_fork` / `session_before_tree` / `session_before_switch` | events | Branching & navigation |

For the full list and exact result types, see
`Sources/PiSwiftCodingAgent/Core/Hooks/HookTypes.swift`.

## Examples in this directory

- `greet.swift` — simplest starter (event handler + command + shortcut)
- `session-timer.swift` — actor state, status bar, agent_end hook
- `permission-gate.swift` — confirm dangerous bash commands (`tool_call` interception)
- `protected-paths.swift` — block writes to `.env`, `.git/`, `node_modules/`
- `git-checkpoint.swift` — `pi.exec`, `session_before_fork`, async actor for state

## SPM packages with dependencies

For multi-file extensions or extensions that need npm-style dependencies,
write a Swift Package and drop it under `~/.pi/agent/extensions/<name>/`:

```
~/.pi/agent/extensions/my-ext/
├── Package.swift
└── Sources/
    └── MyExt/
        └── main.swift     # @_cdecl("piExtensionMain") entry point
```

`Package.swift` should produce a dynamic library product. PiSwift runs
`swift build --configuration release --package-path <dir>` on first use and
caches the resulting dylib.

## Concurrency notes

- The factory closure is called once per session start. Top-level state goes
  in module-level lets (preferably an `actor` for mutable state).
- Event handlers may be invoked concurrently. Use `actor`s, `LockedState`,
  or `@MainActor` isolation depending on what's accessing the data.
- `ctx.ui` methods need `await`. The protocol is `@MainActor`-isolated.
- Strict concurrency is enabled — `@unchecked Sendable` is not used in this
  project, so closures must be honestly `@Sendable`.

## Debugging

PiSwift caches compiled extension dylibs at `~/.pi/agent/cache/extensions/`.
The cache key includes the source hash + the SDK dylib hash, so a `swift
build` of PiSwift invalidates the cache automatically.

If your extension fails to load, the TUI shows the error in the chat at
startup (or after `/reload`). Compilation errors come straight from `swiftc`.
