This directory contains a port of the pi-mono project from
Mario Zechner to Swift, as I need to embed this into an iPad app:

https://github.com/badlogic/pi-mono

It is split up slightly differently.

## Package boundary

`PiSwiftAgent` is the reusable low-level agent loop/proxy layer. The higher-level
coding-agent harness behavior from `pi-mono/packages/agent` lives in
`PiSwiftCodingAgent` instead of being exposed as a source-compatible generic
`AgentHarness` API. The macOS terminal UI and `pi-coding-agent` executable live
in the sibling `../PiSwiftTui` package so this package stays suitable for mobile
applications. See
`AGENT_HARNESS_API_BOUNDARY.md` for the parity decision.

## Code mode host controls

Hosts can set limits without changes to script source:

```swift
let codeMode = createCodemodeExtension(options: CodemodeExtensionOptions(
    mode: .on,
    inlineBudget: 0,
    defaultTimeoutMs: 60_000,
    maxTimeoutMs: 600_000,
    validationErrorPrefix: "validation: ",
    searchResultDetail: .summary
))
```

`CodemodeExtensionOptions.inlineBudget` is a session extension override. It takes
precedence over `codemode.inlineBudget` in settings without writing a settings
file. Set it to `0` to omit all inline tool declarations. Tools with `.codemode`
or `.deferred` exposure remain callable and available through discovery. Use
`.deferred` when a tool must stay out of the inline catalog for every budget.
The default budget remains 3000 estimated tokens.

`CodemodeSearchResultDetail` has `.full` and `.summary` cases. Set the additive
`searchResultDetail` option on `CodemodeExtensionOptions` (or
`CodemodeToolOptions`) to `.summary` for rows with exactly `name`, `namespace`,
and `description`. The namespace is `null` when absent; the description is at
most 160 characters. Summary rows have no declarations or schemas. The default
`.full` keeps the existing `{ name, description }` rows with full tool samples.
In summary mode, search for relevant tools, call `describeTool(name)` for each
selected tool, then execute calls and return selected results. `describeTool`
keeps the full description, guidance, input declaration, and output schema.
Ranking, namespace filters, and `ALL_TOOLS` keep their existing behavior.

The optional `recordDiscoveryCall` callback on each options type receives
`searchTools`, `describeTool`, or `describeNamespace` once per runtime dispatch.
Use it to measure actual discovery calls, including loops and invalid arguments.
The default is `nil`; the callback does not change results or native call records.

`defaultTimeoutMs` and `maxTimeoutMs` are optional. The same fields are available
in `CodemodeSettings` and the `codemode` settings object. Extension options take
precedence over settings. A script can request a timeout on its first line:
`// @options: {"timeout_ms": 600000}`. A request above the host maximum fails with
an error that gives the maximum. A script without `timeout_ms` uses the default,
and the maximum also limits that default. With only `maxTimeoutMs` set, the
maximum is the timeout. With both options unset, the existing timeout
behavior stays in use. A host timeout ends the wait. It cannot guarantee that
a JavaScriptCore thread or a native operation has stopped on iOS.

The host dispatches each call that a script makes before its result. When the script
ends, the host cancels the calls that are not complete. A call that did not start has
the status `cancelled` and the error "Execution ended before the tool call started".
After a script ends, later bridge calls are rejected before tool dispatch.
Their bounded call records use `rejected_after_end`. `CodemodeRuntimeResult.rejectedCalls`
remains available for attempts after the host returns. The built-in extension saves
late call details as `codemode-late-call` session entries, with the parent tool-call
ID and the call row. It retains at most 128 such rows per execution, with bounded
argument and error previews. A late bridge call also rejects its JavaScript promise.
When the host abandons a JavaScriptCore thread, it records rejected calls from that
thread for 60 seconds (`CodemodeToolOptions.lateCallWindow`). After that time, the
execution releases its call state, and `rejectedCalls` still holds the calls.
For a native operation whose result is uncertain, return `AgentToolResult.details` with `{"outcome": "unknown"}`.
Code mode records `outcome_unknown` and lists these calls separately in error and
abort summaries. The caller must inspect the operation before a retry. Keep an
existing error prefix in the result text. Code mode runs `prepareArguments` and
schema validation for each nested call before the host tool hook runs. The session
does not run `prepareArguments` again. It validates the arguments again against the
tool that it executes, because a live registration can replace that tool. The
optional `validationErrorPrefix` is added to the code mode argument failures.

Set `CreateAgentSessionOptions.toolNameCollisionPolicy` to `.reject` to reject
duplicate tool names and JavaScript identifiers such as `edit-node` and
`edit_node`. The default is `.overwrite` for compatibility. A rejected extension
registration returns `HookAPIError` and produces a diagnostic. An extension can
register its own tool again, for example to hide it. Only the built-in tools that the
session creates reserve their names. An extension that registers the tool name of a
replaceable built-in extension replaces that built-in extension, as with `.overwrite`.
Extension load failures are `error` diagnostics with each policy. Extension tools
retain registration order. `ToolInfo.ownerPath` identifies the owner of the
executable registration, including live replacements. `ToolNamespace.version`
is optional and appears as `version` in `describeNamespace` output.

## MCP adapter extension

`PiMCPAdapter` is an opt-in inline extension. Applications provide MCP
configuration in code. The adapter does not read or write project, home, or
third-party MCP config files.

```swift
import PiMCPAdapter
import PiSwiftCodingAgent

let adapter = McpAdapter.makeExtension(McpAdapterOptions(
    config: McpConfig(mcpServers: [
        "docs": ServerEntry(url: "https://mcp.example.com/mcp")
    ])
))

let result = await createAgentSession(CreateAgentSessionOptions(
    inlineExtensions: [adapter.inlineExtension()]
))

let status = await adapter.runtime.status()
```

The extension registers the `mcp` proxy tool. It also registers direct tools
when cached or live metadata enables them, and updates direct tools and prompt
commands during the session after a metadata refresh. Hosts can subscribe to
`mcpStatusEvent` and use the runtime status API to build native UI. The adapter
does not include terminal panels or a WebView renderer.

OAuth is closed by default. A host that needs OAuth must supply an
`McpAuthorizationProvider`, which can use its own secure credential store. The
adapter does not read token files from the user's home directory.

The runtime also provides `connect`, `disconnect`, `reconnect`, `logout`,
`callTool`, `readResource`, `listTools`, `listResources`, `listPrompts`, and
`getPrompt`. MCP prompts register namespaced slash commands. Set `sampling` or
`elicitation` and provide a
`serverRequestHandler` to enable server-initiated requests. The adapter does
not advertise those capabilities without that handler.

MCP text output has a guard by default. It limits inline text to 50 KiB or
2,000 lines and keeps images. Proxy-tool details limit raw MCP results to
16 KiB and replace larger values with a compact reference. Hosts can set
`outputGuard` to `false` or supply an `McpOutputStore` for complete-output
artifacts.

Tracing is disabled unless both `settings.trace.enabled` (or a server's
`trace`) and an `McpTraceSink` are supplied. Trace events contain only
redacted server and method metadata, direction, message type, and byte count.
They never contain MCP payloads, headers, URLs, or authorization values. The
host owns trace retention and storage.

## Subagents (in-process)

PiSwift supports delegating work to specialized subagents without spawning a subprocess. Subagents are defined by user-editable Markdown files and run in-process with isolated context.

### Agent locations

- User agents: `~/.pi/agent/agents`
- Project agents: `.pi/agents` (nearest parent of the current working directory)

### Agent file format

Each agent is a `.md` file with YAML-style frontmatter. The body becomes the agent’s system prompt.

Example:

```
---
name: worker
description: General-purpose subagent
model: gpt-5.2
tools: read,edit,write,bash
outputFormat: |
  ## Completed
  ## Files Changed
  ## Notes
---

You are a worker agent with full capabilities.
```

Supported frontmatter keys:
- `name` (required): agent name used in tool calls.
- `description`: shown in listings and error messages.
- `tools`: comma-separated tool names. Use `all` to enable all built-in tools (excluding `subagent`).
- `model`: model pattern (e.g. `openai/gpt-5.2` or `gpt-5.2`).
- `outputFormat`: appended to the system prompt as an “Output format” section.

### Subagent tool usage

The `subagent` tool supports three modes:

1) Single:
```
{ "agent": "worker", "task": "Summarize the tests in Tests/." }
```

2) Parallel:
```
{ "tasks": [
  { "agent": "worker", "task": "Scan Sources/ for concurrency violations." },
  { "agent": "reviewer", "task": "Review README for updates." }
] }
```

3) Chain:
```
{ "chain": [
  { "agent": "planner", "task": "Plan the fix for X." },
  { "agent": "worker", "task": "Implement the plan:\n{previous}" }
] }
```

Optional parameters:
- `agentScope`: `user`, `project`, or `both` (default: `user`).
- `cwd`: per-task working directory (single/parallel/chain items).

### Notes

- Subagents run in-process; no subprocess is spawned.
- If `tools` is omitted, the default coding toolset is used.
- If `model` is omitted, the main agent’s selected model is used.

## Prompt templates

Prompt templates are Markdown files that expand when you type `/name` in the prompt.

Locations:
- User templates: `~/.pi/agent/prompts`
- Project templates: `.pi/prompts` (nearest parent of the current working directory)

Template body supports `$1`, `$2`, `$ARGUMENTS`, and `$@` substitutions.

## Default model priority

When no model is selected, the default fallback order is:
1. anthropic: `claude-sonnet-4-5`
2. openai: `gpt-5.2`
3. openai-codex: `gpt-5.2-codex`
4. opencode: `claude-opus-4-5`

## Model catalog

The built-in model catalog is generated from a sibling pi-mono checkout:

```sh
cd PiSwift
node Scripts/generate-ai-catalogs.js
```

It needs `../pi-mono` checked out at the pinned revision, now `6fb2e7815`.
It writes `Sources/PiSwiftAI/ModelsData.swift`, `ImageModelsData.swift`,
`ClassifierModelsData.swift`, and the `upstream-*.generated.json` fixtures in
`Tests/PiSwiftAITests/Resources/`. Do not edit these files by hand. At the
pinned revision, the output must be identical to the committed files. When
you move the pin, record the new revision here.

`Sources/PiSwiftAI/ModelNameCorrections.swift` corrects some upstream display
names. The corrections apply to the built-in catalog and to the pi.dev catalog
overlay. Names from `models.json` are not changed. See
`Scripts/model-name-audit.md` for the decisions and sources.

## Provider request payloads

Use `onPayload` to inspect or replace the final JSON request body. The provider
waits for this async callback before it sends the request. Return `nil` to keep
the body. Return a `PayloadSnapshot` with a JSON object to replace it. A thrown
error stops the request before transport retries start.

For example, set the service tier on an OpenAI request:

```swift
let options = SimpleStreamOptions(onPayload: { snapshot in
    guard var payload = try JSONSerialization.jsonObject(
        with: Data(snapshot.json.utf8)
    ) as? [String: Any] else { return nil }
    payload["service_tier"] = "fast"
    let data = try JSONSerialization.data(withJSONObject: payload)
    return PayloadSnapshot(json: String(decoding: data, as: UTF8.self))
})
```

This also works through `AgentOptions.onPayload`. Coding agent extensions can
return `BeforeProviderRequestEventResult(payload: json)` from a
`before_provider_request` handler. Handlers run in order; each handler receives
the payload returned by the previous handler. A `nil` result keeps that payload.
As with other extension hooks, handler errors are reported and later handlers
continue.

Existing callbacks that only inspect the payload must now return `nil`.

## Strict concurrency + errors

This port builds with strict concurrency. Some lock-backed wrappers still use
`@unchecked Sendable`; see `CONCURRENCY_FATALERROR_AUDIT.md` for the current
inventory and cleanup plan. Errors use Swift enums that conform to
`LocalizedError` instead of `NSError`.

## Sample subagent

See `examples/subagents/fetcher.md` for a sample agent that uses `curl` via the `bash` tool to fetch files from the internet.
