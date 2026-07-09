# Coding Agent Porting Status (JS -> Swift)

This document tracks parity between the JS module in `pi-mono/packages/coding-agent` and the Swift module under `PiSwift`.

For the broader `pi-mono/packages/agent` harness boundary, see
`AGENT_HARNESS_API_BOUNDARY.md`. The Swift port intentionally keeps the reusable
loop/proxy primitives in `PiSwiftAgent` and the coding-agent harness behavior in
`PiSwiftCodingAgent`/`PiSwiftCodingAgentTui`.

## Ported (feature-complete or very close)
- Core tools: `pi-mono/packages/coding-agent/src/core/tools/*` -> `Sources/PiSwiftCodingAgent/Core/Tools/*`
- Compaction + branch summarization: `pi-mono/packages/coding-agent/src/core/compaction/*` -> `Sources/PiSwiftCodingAgent/Core/Compaction/*`
- Model resolver + registry: `pi-mono/packages/coding-agent/src/core/model-resolver.ts` -> `Sources/PiSwiftCodingAgent/Core/ModelResolver.swift`; `pi-mono/packages/coding-agent/src/core/model-registry.ts` -> `Sources/PiSwiftCodingAgent/Core/ModelRegistry.swift`
- Session manager: `pi-mono/packages/coding-agent/src/core/session-manager.ts` -> `Sources/PiSwiftCodingAgent/Core/SessionManager.swift`
- Agent session core (steer/followUp, concurrency guard): `pi-mono/packages/coding-agent/src/core/agent-session.ts` -> `Sources/PiSwiftCodingAgent/Core/AgentSession.swift`
- Settings, auth storage, bash executor, messages:
  - `pi-mono/packages/coding-agent/src/core/settings-manager.ts` -> `Sources/PiSwiftCodingAgent/Core/SettingsManager.swift`
  - `pi-mono/packages/coding-agent/src/core/auth-storage.ts` -> `Sources/PiSwiftCodingAgent/Core/AuthStorage.swift`
  - `pi-mono/packages/coding-agent/src/core/bash-executor.ts` -> `Sources/PiSwiftCodingAgent/Core/BashExecutor.swift`
  - `pi-mono/packages/coding-agent/src/core/messages.ts` -> `Sources/PiSwiftCodingAgent/Core/Messages.swift`
- Skills + system prompt stack: `pi-mono/packages/coding-agent/src/core/skills.ts` + `system-prompt.ts` -> `Sources/PiSwiftCodingAgent/Core/Skills.swift` + `Sources/PiSwiftCodingAgent/Core/SystemPrompt.swift`
- Slash commands + @file expansion: `pi-mono/packages/coding-agent/src/core/slash-commands.ts` -> `Sources/PiSwiftCodingAgent/Core/SlashCommands.swift` (shared `$ARGUMENTS`, `${N:-default}`, and `${@:N[:L]}` substitution)
- CLI helpers: `pi-mono/packages/coding-agent/src/cli/file-processor.ts`, `list-models.ts`, `session-picker.ts` -> `Sources/PiSwiftCodingAgent/CLI/*` (`--list-models` includes `models.json` diagnostics and header-auth-backed availability)
- Utilities: `pi-mono/packages/coding-agent/src/utils/fuzzy.ts` -> `Sources/PiSwiftCodingAgent/Utils/Fuzzy.swift`; `pi-mono/packages/coding-agent/src/utils/mime.ts` -> `Sources/PiSwiftCodingAgent/Utils/Mime.swift`; glob handling in `Sources/PiSwiftCodingAgent/Utils/Glob.swift`; tools manager in `Sources/PiSwiftCodingAgent/Utils/ToolsManager.swift`
- Shell/clipboard/changelog utils + timings/migrations: `pi-mono/packages/coding-agent/src/utils/{shell,clipboard,changelog}.ts` + `src/core/timings.ts` + `src/migrations.ts` -> `Sources/PiSwiftCodingAgent/Utils/{Shell,Clipboard,Changelog}.swift`, `Sources/PiSwiftCodingAgent/Core/Timings.swift`, `Sources/PiSwiftCodingAgent/Migrations.swift`
- Exec helper: `pi-mono/packages/coding-agent/src/core/exec.ts` -> `Sources/PiSwiftCodingAgent/Core/Exec.swift`
- Interactive mode + components (MiniTui): `pi-mono/packages/coding-agent/src/modes/interactive/*` -> `Sources/PiSwiftCodingAgent/Modes/Interactive/*`
- Theme loading + JSON themes: `pi-mono/packages/coding-agent/src/modes/interactive/theme/*` -> `Sources/PiSwiftCodingAgent/Modes/Interactive/Theme.swift` + `Sources/PiSwiftCodingAgent/Resources/theme/*`
- CLI orchestration + TUI: `pi-mono/packages/coding-agent/src/main.ts` + `cli.ts` -> `Sources/PiSwiftCodingAgentCLI/PiCodingAgentCLI.swift` (interactive mode wiring)
- SDK: `pi-mono/packages/coding-agent/src/core/sdk.ts` -> `Sources/PiSwiftCodingAgent/Core/SDK.swift` (custom tools discovery, hook discovery supports bundles, agent-level before/after tool hook adapters)
- Hook loader + tool wrapper: `pi-mono/packages/coding-agent/src/core/hooks/loader.ts`, `pi-mono/packages/coding-agent/src/core/hooks/tool-wrapper.ts` -> `Sources/PiSwiftCodingAgent/Core/Hooks/HookLoader.swift`, `Sources/PiSwiftCodingAgent/Core/Hooks/ToolWrapper.swift` (bundle-based hooks)
- Hook runtime: `pi-mono/packages/coding-agent/src/core/hooks/runner.ts` -> `Sources/PiSwiftCodingAgent/Core/Hooks/HookRunner.swift` (context/before_agent_start/session/agent/turn/project_trust events; `ctx.mode`, trust, tool metadata, system-prompt option context, and pre-trust global-extension evaluation)
- Extension provider/resource/lifecycle parity:
  - Dynamic provider registration/unregistration via `HookAPI` and `ModelRegistry`.
  - `resources_discover` overlays for extension skills, prompts, and themes with provenance metadata.
  - `message_*` and `tool_execution_*` lifecycle dispatch from `AgentSession`.
  - Main command/context APIs and UI helpers documented in `EXTENSION_API_PARITY.md`.
- Settings/default parity:
  - `transport` defaults to `.auto` and legacy `websockets` migrates.
  - `defaultProjectTrust`, analytics/tracking ID, editor padding, hardware cursor, markdown indentation, HTTP idle timeout, and WebSocket connect timeout are parsed, saved, merged, and tested.
  - HTTP/WebSocket timeouts are routed into agent/provider construction.
- Custom tools pipeline: `pi-mono/packages/coding-agent/src/core/custom-tools/*` -> `Sources/PiSwiftCodingAgent/Core/CustomTools/*` + CLI/TUI wiring
- RPC mode: `pi-mono/packages/coding-agent/src/modes/rpc/*` -> `Sources/PiSwiftCodingAgent/Modes/RpcMode.swift` (JSON protocol + hook UI + command handling)
- RPC mode tests: `pi-mono/packages/coding-agent/test/rpc.test.ts` -> `Tests/PiSwiftCodingAgentTests/RpcModeTests.swift` + `Tests/PiSwiftCodingAgentTests/RpcTestClient.swift` (live-gated RPC client)
- RPC client API: `pi-mono/packages/coding-agent/src/modes/rpc/rpc-client.ts` + `rpc-types.ts` -> `Sources/PiSwiftCodingAgent/Modes/RpcClient.swift` (public Swift RPC client + types)
- Export HTML: `pi-mono/packages/coding-agent/src/core/export-html/*` -> `Sources/PiSwiftCodingAgent/Core/ExportHtml.swift` + `Sources/PiSwiftCodingAgent/Resources/export-html/*`
- Print mode: `pi-mono/packages/coding-agent/src/modes/print-mode.ts` -> `Sources/PiSwiftCodingAgent/Modes/PrintMode.swift` (JSON event stream + ANSI markdown rendering + output flush)
- Prompt templates: `pi-mono/packages/coding-agent/src/core/prompt-templates.ts` -> `Sources/PiSwiftCodingAgent/Core/PromptTemplates.swift` (loading, metadata, and shared slash-command argument substitution)
- CLI args parsing + wiring: `pi-mono/packages/coding-agent/src/cli/args.ts` -> `Sources/PiSwiftCodingAgent/CLI/Args.swift` + `Sources/PiSwiftCodingAgentCLI/CLIOptions.swift` + `Sources/PiSwiftCodingAgentCLI/PiCodingAgentCLI.swift` (ArgumentParser + help snapshot tests)

## Partial / stubs (implemented but missing JS behavior)
- OAuth login + token refresh workflows (JS `packages/ai/src/utils/oauth/*`):
  - Anthropic OAuth (PKCE auth code with manual code paste) (done).
  - OpenAI Codex OAuth (PKCE + local callback server + manual paste fallback + accountId extraction) (done).
  - Shared helpers (`getOAuthApiKey`, token refresh, provider list) and CLI `/login` + OAuth selector (done).
  - GitHub Copilot device-code flow + model enablement.

## Not required
- Google Gemini CLI and Google Antigravity built-in OAuth/model/default registration: removed upstream after v0.70.5, so Swift no longer lists them as default providers. Legacy helper code remains in `PiSwiftAI` for source compatibility.
- Config + package detection/versioning: `pi-mono/packages/coding-agent/src/config.ts` -> `Sources/PiSwiftCodingAgent/Config.swift` (no package.json-driven name/version, bun/tsx detection, theme/export path resolution logic)

## Task Queue (next in order)
- [x] RPC mode tests: port `test/rpc.test.ts` using Swift Testing (gate on API keys, implement a Swift RPC test client that spawns `pi-coding-agent --mode rpc`).
- [x] RPC client API: port `src/modes/rpc/rpc-client.ts` + `rpc-types.ts` as a public Swift client for programmatic access.

## Delta from `pi-mono/packages/coding-agent` (pending parity)
- [x] Event bus for hooks/tools (`pi.events`), tool `sendMessage`, and `deliverAs: "nextTurn"` queue semantics (clear on new/switch/branch).
- [x] Hook API extensions: `systemPromptAppend`, error stack traces, deep-copy context messages, setTitle/setWidget UI hooks.
- [x] Plan-mode hook parity (todo extraction, widget + final list, tool_result/turn_end tracking).
- [x] Tool registry/tool control parity (full registry even when scoped, agent-level hook dispatch for active tools).
- [x] Agent-level tool hook parity: `tool_call` blocking and `tool_result` content/details/isError overrides for successful and error tool results.
- [x] Extension context surfaces (`ctx.mode`, `ctx.isProjectTrusted()`, `ctx.getSystemPromptOptions()`) and `project_trust` event/result types.
- [x] Project trust startup bootstrap: pre-trust global extension loading, `project_trust` dispatch, project extension/resource gating when untrusted, and shared config/package command trust resolution.
- [x] Startup subprocess marker (`PI_CODING_AGENT=true`) for package/config/normal CLI runs.
- [x] Offline startup/package mode (`--offline`, `PI_OFFLINE=1`) wired through CLI, SDK resource loading, config/package commands, and package manager network suppression.
- [x] `--list-models` diagnostics and header-auth availability for `models.json` custom providers.
- [x] AI model registry consumer parity for v0.79.4 generated built-ins: Swift now exposes the 971-model text catalog, including new generated providers used by coding-agent model discovery, while Google Gemini CLI and Google Antigravity remain excluded from default built-in model registration.
- [x] AI provider request-control consumer parity: `StreamOptions` / `SimpleStreamOptions` now preserve provider `timeoutMs`, `maxRetries`, `onResponse`, and Codex WebSocket connect timeout through built-in provider registration.
- [x] AI Chat Completions cache consumer parity: `cacheRetention` and `sessionId` now flow into OpenAI-compatible options and request shaping, including Anthropic-style `cache_control`, session-affinity headers, and prompt-cache fields for compatible providers.
- [x] AI Anthropic provider compat parity: Swift now applies v0.79.4 eager tool streaming, tool cache-control, long cache-retention opt-out, and explicit disabled-thinking request shaping for Anthropic-compatible providers.
- [x] AI `models.json` compat consumer parity: provider-level compat override-only entries preserve built-in model lists, custom built-in-provider models inherit built-in API/base URL defaults, and provider/model compat fields merge.
- [x] RPC prompt preflight, model-aware header-auth checks for prompt/model selection paths, bash `excludeFromContext`, `get_session_stats.contextUsage`, child-exit pending-request rejection, stderr forwarding, and stdout JSONL guarding.
- [x] HTML export markdown-link URL sanitization, HTML-like content rendered verbatim, selection-safe expandable toggles, browser-safe header toggle shortcuts, plain-text output indentation, tightened tool spacing, and structured grep/find/ls output rendering.
- [x] Keybinding & slash command parity (`/quit` + `/exit`, configurable keybindings, robust shortcut matching, `$ARGUMENTS` for slash commands).
- [x] Image handling parity (auto-resize toggle, read tool resize + dimension note, consistent placeholders, clipboard paste).
- [x] Interactive terminal title refresh after `/name` and extension-driven `pi.setSessionName()`.
- [x] OAuth parity for `pi-mono/packages/ai`: GitHub Copilot device flow, token exchange, model enablement, base URL extraction, and auth-key conversion are implemented and covered by offline tests.
- [x] Gemini provider parity: Google Generative AI, Vertex, Gemini CLI, and Antigravity request/usage/auth paths are implemented and covered by focused AI tests where applicable.
- [x] Extension provider/resource/lifecycle parity: dynamic provider registration, `resources_discover`, message/tool lifecycle hooks, and main command/context APIs are implemented or documented as Swift differences in `EXTENSION_API_PARITY.md`.
- [x] Settings/transport parity: the drifted settings keys identified by the audit are supported and tested, and transport/timeouts reach agent construction.
- [x] Process-mode parity: output guarding, print/RPC stdout cleanliness, and signal shutdown cleanup are implemented and covered by focused tests.
- [x] MiniTui editor parity: editor padding plus autocomplete trigger/debounce behavior are implemented and covered by MiniTui tests.
