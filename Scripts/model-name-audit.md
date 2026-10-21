# Model display-name audit

Audit date: 2026-10-20. Catalog: pi-mono `6fb2e7815`.

`Sources/PiSwiftAI/ModelNameCorrections.swift` corrects only one type of
problem: an alias for one fixed version, with a label that suggests it is the
newest model across versions. Each correction is an explicit row that applies
only to the exact upstream name. The test `modelNameCorrectionsMatchUpstream`
fails when upstream changes a name, so that the row can be removed.

The names come from models.dev through pi-mono's
`packages/ai/scripts/generate-models.ts`. The correct place for a permanent fix
is models.dev.

## Corrected

| Group | Decision | Source |
|---|---|---|
| anthropic, cloudflare-ai-gateway, github-copilot: `claude-{haiku,opus,sonnet}-4-5` (and `claude-haiku-4.5`), named "… 4.5 (latest)" | Remove "(latest)". The 4.5 aliases point to the dated 4.5 snapshot, not to the newest Claude model. | Anthropic, [Models overview](https://platform.claude.com/docs/en/about-claude/models/overview): "For models before the 4.6 generation, the alias is a convenience pointer that resolves to the dated ID." |
| anthropic: `claude-{haiku,opus,sonnet}-4-5-YYYYMMDD` | Add the snapshot date to the name, so that names stay unique within the provider after the alias rename. | Same source. |

## Not changed

| Group | Decision | Source |
|---|---|---|
| openai, azure: `gpt-5-chat-latest` "GPT-5 Chat Latest", `gpt-5.2-chat-latest` "GPT-5.2 Chat", `gpt-5.3-chat-latest` "GPT-5.3 Chat (latest)" | Keep. Each alias points to the ChatGPT snapshot of one version, and "latest" is part of OpenAI's own ID. The names are not consistent with each other (follow-up). All three are deprecated. | OpenAI model pages: [gpt-5-chat-latest](https://developers.openai.com/api/docs/models/gpt-5-chat-latest) ("points to the GPT-5 snapshot previously used in ChatGPT"), [gpt-5.2-chat-latest](https://developers.openai.com/api/docs/models/gpt-5.2-chat-latest), [gpt-5.3-chat-latest](https://developers.openai.com/api/docs/models/gpt-5.3-chat-latest) ("points to the GPT-5.3 Instant snapshot used in ChatGPT") |
| openai, azure: `gpt-daybreak-{blue,red}-latest` "Daybreak Blue/Red" | Keep. The names do not say "latest". | [gpt-daybreak-blue-latest](https://developers.openai.com/api/docs/models/gpt-daybreak-blue-latest): default snapshot `gpt-5.6-sol`, deprecated |
| google, google-vertex: `gemini-flash-latest`, `gemini-flash-lite-latest` | Keep. Family aliases that move to new releases. | Google, [Gemini models](https://ai.google.dev/gemini-api/docs/models): "This alias will get hot-swapped with every new release of a specific model variation." |
| openrouter: `~*/…-latest`, `openai/gpt-chat-latest` | Keep. Family aliases that move to new releases. `~deepseek/deepseek-v4-flash-latest` "DeepSeek V4 Flash Latest" is the newest model of the V4 Flash family, and the name says so. | OpenRouter `GET https://openrouter.ai/api/v1/models` descriptions: "This model always redirects to the latest model in the … family." |
| mistral: `*-latest` | Keep. Mistral moves `-latest` aliases to new versions. | Mistral [changelog](https://docs.mistral.ai/resources/changelogs), for example "`mistral-ocr-latest` now points to it" (2026-06-23), and `mistral-large-latest` pointing to successive versions (2024). |
| mistral: `devstral-latest` "Devstral 2", `devstral-medium-latest` "Devstral 2 (latest)" | Keep (not verified). No official source found for the current targets. The version "2" in a rolling alias name can become wrong. Follow-up. | Not found in Mistral docs on 2026-10-20. |
| fireworks: `accounts/fireworks/routers/*-latest` | Keep (not verified). "GLM 5.3 Fast (Latest)", "GLM Flash Latest (GLM 5.3 Flash)" and "Qwen Max Latest (Qwen3.8 Max)" name a version in a router name, which becomes wrong when the router moves. Follow-up. | No official Fireworks router documentation found on 2026-10-20. |
| vercel-ai-gateway: `mistral/mistral-medium-3.5` "Mistral Medium Latest" | Keep (not verified). The ID is a fixed version but the name says "Latest". This is the opposite problem. Follow-up. | [Vercel model page](https://vercel.com/ai-gateway/models/mistral-medium-3.5) does not say whether the ID moves. |
