# Coding Agent Porting Status (JS -> Swift)

This document tracks parity between the JS module in `pi-mono/packages/coding-agent` and the Swift module under `PiSwift`.

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
- SDK: `pi-mono/packages/coding-agent/src/core/sdk.ts` -> `Sources/PiSwiftCodingAgent/Core/SDK.swift` (custom tools discovery + wrapping, hook discovery supports bundles)
- Hook loader + tool wrapper: `pi-mono/packages/coding-agent/src/core/hooks/loader.ts`, `pi-mono/packages/coding-agent/src/core/hooks/tool-wrapper.ts` -> `Sources/PiSwiftCodingAgent/Core/Hooks/HookLoader.swift`, `Sources/PiSwiftCodingAgent/Core/Hooks/ToolWrapper.swift` (bundle-based hooks)
- Hook runtime: `pi-mono/packages/coding-agent/src/core/hooks/runner.ts` -> `Sources/PiSwiftCodingAgent/Core/Hooks/HookRunner.swift` (context/before_agent_start/session/agent/turn/project_trust events; `ctx.mode`, trust, tool metadata, system-prompt option context, and pre-trust global-extension evaluation)
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
- [x] Tool registry/tool control parity (full registry even when scoped, wrap all tools).
- [x] Extension context surfaces (`ctx.mode`, `ctx.isProjectTrusted()`, `ctx.getSystemPromptOptions()`) and `project_trust` event/result types.
- [x] Project trust startup bootstrap: pre-trust global extension loading, `project_trust` dispatch, project extension/resource gating when untrusted, and shared config/package command trust resolution.
- [x] Startup subprocess marker (`PI_CODING_AGENT=true`) for package/config/normal CLI runs.
- [x] `--list-models` diagnostics and header-auth availability for `models.json` custom providers.
- [x] RPC prompt preflight and model-aware header-auth checks for prompt/model selection paths.
- [x] Keybinding & slash command parity (`/quit` + `/exit`, configurable keybindings, robust shortcut matching, `$ARGUMENTS` for slash commands).
- [x] Image handling parity (auto-resize toggle, read tool resize + dimension note, consistent placeholders, clipboard paste).
- [ ] OAuth parity for `pi-mono/packages/ai` (see "Partial / stubs"): remaining GitHub Copilot flow.
- [ ] Gemini provider parity (Google Generative AI + Vertex support, including tests where applicable).
