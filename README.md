This directory contains a port of the pi-mono project from
Mario Zechner to Swift, as I need to embed this into an iPad app:

https://github.com/badlogic/pi-mono

It is split up slightly differently.

## Package boundary

`PiSwiftAgent` is the reusable low-level agent loop/proxy layer. The higher-level
coding-agent harness behavior from `pi-mono/packages/agent` lives in
`PiSwiftCodingAgent` and `PiSwiftCodingAgentTui` instead of being exposed as a
source-compatible generic `AgentHarness` API. See
`AGENT_HARNESS_API_BOUNDARY.md` for the parity decision.

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

## Strict concurrency + errors

This port builds with strict concurrency. Some lock-backed wrappers still use
`@unchecked Sendable`; see `CONCURRENCY_FATALERROR_AUDIT.md` for the current
inventory and cleanup plan. Errors use Swift enums that conform to
`LocalizedError` instead of `NSError`.

## Sample subagent

See `examples/subagents/fetcher.md` for a sample agent that uses `curl` via the `bash` tool to fetch files from the internet.
