# Using Codex image generation in PiSwift

`PiCodexImageGen` is an inline extension. It lets the agent generate and edit
images through the ChatGPT subscription (the Codex backend, with the native
`image_generation` tool). It is a port of pi-extras `pi-codex-image-gen`.

The extension is active **only** when the session model uses the
`openai-codex` provider (a ChatGPT login). It uses the session's own login,
ChatGPT account and model. You do not set up a separate image login, API key
or configuration file.

## 1. Add the dependency

In your `Package.swift`, add the `PiCodexImageGen` product to your target:

```swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "PiSwiftCodingAgent", package: "PiSwift"),
        .product(name: "PiCodexImageGen", package: "PiSwift"),
    ]
)
```

## 2. Add the extension to the session

```swift
import PiCodexImageGen
import PiSwiftAI
import PiSwiftCodingAgent

let agentDir = getAgentDir()
let result = try await createAgentSession(CreateAgentSessionOptions(
    agentDir: agentDir,
    model: getModels(provider: .openaiCodex).first,
    inlineExtensions: [CodexImageGen.inlineExtension(agentDir: agentDir)]
))
let session = result.session
```

Give the same `agentDir` to the session and to the extension. Global image
saves then stay in that directory. This is important in a sandboxed app (iOS,
iPadOS, sandboxed macOS). `CodexImageGen.inlineExtension` without an argument
uses `getAgentDir()`.

If you register extensions yourself on a `HookAPI`, use
`CodexImageGen.register(pi, agentDir: agentDir)`.

## 3. Log in to ChatGPT

The session needs `openai-codex` OAuth credentials in its `AuthStorage`. Use
the same login as for ChatGPT chat:

```swift
try await authStorage.login(.openAICodex, callbacks: myOAuthCallbacks)
```

In the PiSwift CLI, type `/login openai-codex`.

## 4. Select a ChatGPT model

The tools appear after a `session_start` or `model_select` event with an
`openai-codex` model. They are not present before that event. If the session
changes to a model from another provider, the extension removes the tools.
If the session changes back, it adds them again.

```swift
if let model = getModels(provider: .openaiCodex).first {
    try await session.setModel(model)
}
```

Any `openai-codex` model in the catalog activates the tools. The same model
names under the `openai` provider (API key) do **not** activate them. The
session model routes the request; the backend selects the image model.

## Durable harness (PiSwiftDurable)

A durable harness does not use `HookAPI` extensions. Install the durable
extension in the registry instead:

```swift
let imageExtension = try CodexImageGen.durableExtension(
    agentDir: agentDir, modelRegistry: modelRegistry, defaultCwd: cwd)
try registry.install(imageExtension)
```

The durable extension has only `codex_generate_image`. It does not have the
artifact tool, the list tool or `/image-artifacts`. The tool reads the
conversation entries for `numLastImagesToInclude`.

The model must see the tool only for an `openai-codex` model. Set the
extension selection together with each model change:

```swift
try await conversation.configure(change: AgentChange(
    model: .set(model),
    extensions: CodexImageGen.durableExtensionChange(for: model, in: imageExtension)
), context: .background)
```

Do this also when you open a conversation. `durableExtensionChange` replaces
the full extension selection. Use it only if the host selects no other
extensions.

## What the agent gets

| Name | Kind | Result |
|---|---|---|
| `codex_generate_image` | Direct model tool | A summary and an inline image block |
| `codex_generate_image_artifact` | Codemode tool | Metadata with `artifact.path` (a private temporary original), no image bytes |
| `codex_list_image_artifacts` | Tool | Artifact records on the current branch, with pages (`offset`, `limit`, `revision`) |
| `/image-artifacts` | Command | The last 20 artifact paths on the current branch |

The list tool and the command do not use quota or the network.

### Generation parameters

| Parameter | Values |
|---|---|
| `prompt` (required) | 1 to 32,000 characters |
| `outputFormat` | `png` (default), `jpeg`, `webp` |
| `background` | `auto`, `opaque`, `transparent` (transparent needs `png` or `webp`) |
| `referencedImagePaths` | Up to 5 local images to edit. Relative paths start at the session `cwd`. `~` is the home directory. |
| `numLastImagesToInclude` | 1 to 5 of the most recent images in the conversation. Do not use it together with `referencedImagePaths`. |
| `save` | `global` (default), `project`, `custom`, `none` |
| `saveDir` | The directory for `save=custom` |

### Where the images go

| `save` | Directory |
|---|---|
| `global` | `<agentDir>/generated-images/<session id>/` |
| `project` | `<cwd>/.pi/generated-images/<session id>/` |
| `custom` | `<saveDir>/<session id>/` |
| `none` | No persistent copy |

The extension never overwrites a file. It creates directories with mode 0700
and files with mode 0600. The artifact tool also keeps a private original in
the system temporary directory, also with `save=none`. The user or the OS can
remove these temporary originals. Copy the files that you must keep.

## Limits

- Deadline: 5 minutes for each call, from the start of the call.
- Output image: 32 MiB. Input images: 20 MiB each, 50 MiB in total.
- At most 2 active and 8 queued generations for each ChatGPT account.
- Retries: at most 3, only for HTTP 429, 500, 502, 503 and 504. The extension
  does not retry quota errors, moderation errors, connection errors or
  incomplete streams.
- Each call uses ChatGPT image quota. Quota can be used also if the call fails
  after the request was sent.
- Redirects are not followed, so the login token never goes to another
  origin. The `HTTPS_PROXY` and `NO_PROXY` environment settings apply.

## Troubleshooting

| Message | Cause and action |
|---|---|
| The tools are not in the tool list | The session model is not an `openai-codex` model, or no `session_start` / `model_select` event occurred yet. Select a ChatGPT model. |
| "Missing ChatGPT credentials. Run /login openai-codex." | The `AuthStorage` has no `openai-codex` login. Log in. |
| "The ChatGPT login has no valid account ID." | The token has no ChatGPT account claim. Log in again. |
| "Codex subscription quota is unavailable or exhausted." | Wait for the plan reset or change the plan. |
| "...does not support this image feature..." | The backend refused the request for this model or option. Try another `openai-codex` model. |
| "...aborted after dispatch. Image quota may have been consumed." | The call was cancelled after the request was sent. The extension does not retry. |

## Not included

The port does not include the `images` transport, pixel inspection of the
result, a configuration file, `PI_CODEX_IMAGE_SAVE_*` environment variables,
the `imagegen` skill or the Python CLI.
