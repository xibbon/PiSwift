# PiSwiftDurable

> **Experimental.** The API can change without notice between releases.

PiSwiftDurable ports the library core of `@earendil-works/pi-durable` at
[v1.1.0](https://github.com/earendil-works/pi/tree/v1.1.0/packages/durable).
It uses PiSwiftAI for model types and PiSwiftChord for JSON documents and observation.
The package declares macOS 15 and iOS 18 minimums and uses Swift 6 strict concurrency.

## Concepts

- **Harness** opens a Session and runs durable tasks. All writes use atomic commits.
- **Conversation** is a transcript of immutable entries. Compare handles by `id`.
- **Document** is JSON state changed in a commit. Typed tokens define its scope,
  history, initial value, version, and fork policy. Use Codable, Sendable value types.
- **Task** is a state machine with a stored checkpoint. It belongs to a conversation
  or another task. The built-in tasks run generation, tools, and compaction.
- **Submission** admits input or a write. `wait` returns the stored outcome.
- **Registry** holds process code: extensions, tools, prompt sections, hooks, wrappers,
  and tasks. Conversations store choices by name. Install extensions again on reopen.

Changes are stored before observers receive them. A transcript normally contains
`pi.user`, a positional `pi.system` entry, and `pi.assistant`. Tool rounds also add
`pi.tool-result`. Built-in documents include `pi.agent`, `pi.provider`, `pi.live`,
`pi.inbox`, and `pi.usage`.

Calls take a `ChordContext`. `ChordContext.background` does not cancel.
`ChordContextKey` carries typed values. These names replace upstream `Context` and
`ContextKey`: PiSwiftAI already has a public `Context` (the user-selected rename).
Cancelling a submission wait cancels that wait; it does not withdraw the submission.

## Quick Start

This deterministic example uses `FakeDurableModels` from the package's
PiSwiftDurableTesting support target. For a host model service, supply an implementation
of `DurableModels`. The core does not install a global provider registry.
The imports and body below are checked in `ReadmeExamplesTests.quickStart` and use
the same chat scenario as upstream example 14. Run the body in an async throwing function.

```swift
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurable
import PiSwiftDurableTesting

let context = ChordContext.background
let models = FakeDurableModels(responses: [.message(fauxAssistantMessage(
    content: [.text(TextContent(text: "Paris."))], timestamp: 1))])
let registry = createRegistry()
try registry.install(Extension(name: "terse", sections: [
    section("preamble", tag: false) { _, _ in "You answer in one word." }
]))
let harness = try await Harness.open(storage: MemoryStorage(),
    options: .init(models: models, registry: registry), context: context)
let root = try await harness.root(options: .init(agent: .init(
    model: .set(.init(provider: "faux", modelId: "faux-1")))), context: context)
let submission = try await root.submit(
    .input(content: .text("Capital of France?")), context: context)
let settled = try await submission.wait(context: context)
if let answer = settled.answer {
    let entry = try await root.commit({ tx in try await tx.entry(answer) }, context: context)
    let messages = try entry?.messages()
    print(messages ?? [])
}
try await harness.close(context: context)
```

`submit` stores the input. Generation prepares the prompt, calls the supplied model
service, and commits the answer. `wait` returns `done` or an unanswered outcome.
The example asserts `done`; upstream example 14's integration test also asserts
`Paris.` and the transcript kinds.

## Persist and Resume

`MemoryStorage` keeps data only for the lifetime of its instance. Use SQLite for
restart persistence. In this checked snippet, `path` is a writable SQLite file path;
`models`, `registry`, and `context` are supplied as above. The test gives the fake
model one `Hello.` answer. The same request ID returns the original submission.

```swift
let options = HarnessOptions(models: models, registry: registry)
let first = try await Harness.open(storage: SqliteStorage.open(path: path),
    options: options, context: context)
let root = try await first.root(options: .init(agent: .init(
    model: .set(.init(provider: "faux", modelId: "faux-1")))), context: context)
let original = try await root.submit(.input(content: .text("Hello"),
    requestId: "greeting-1"), context: context)
_ = try await original.wait(context: context)
try await first.close(context: context)

let reopened = try await Harness.open(storage: SqliteStorage.open(path: path),
    options: options, context: context)
let sameRoot = try await reopened.root(context: context)
try reopened.resume()
let again = try await sameRoot.submit(.input(content: .text("Hello"),
    requestId: "greeting-1"), context: context)
// again.id == original.id: no second input is admitted.
let settled = try await again.wait(context: context)
try await reopened.close(context: context)
```

Pending tasks retain their checkpoints and memos on close. Reopen with the task
extensions installed, then call `resume`. Submitting or waiting also enables
scheduling. Upstream example 13's Swift test closes a ticker after tick 2, checks its
saved checkpoint and memos, and resumes through tick 5 without duplicate ticks.
Examples 24 and 31 check child-task and tool recovery with SQLite.

Use one owner for an open storage file. This library does not provide a cross-process
file lock. Close the Harness to stop its work and close its storage.

## Extensions and Tools

The checked example below installs an application tool. `registry` is created with
`createRegistry()`. Install this extension before opening the Harness.

```swift
let echo = try ToolRegistration(name: "echo", description: "Return text",
    parameters: ["type": "object", "properties": .object([
        "text": .object(["type": "string"])
    ]), "required": .array(["text"])], replay: .safe) { args, _, _ in
        ToolExecutionResult(content: [.text(TextContent(
            text: args["text"]?.stringValue ?? ""))])
    }
try registry.install(Extension(name: "echo", tools: [echo]))
```

The Harness validates arguments before execution. A safe tool can run again after an
interrupted execute phase. Declare safe replay only when the tool can repeat its work.
An unsafe interrupted call becomes an interrupted tool result. Tools can use their
bound API for commits, memos, owned tasks, output, details, models, and the host environment.
`Extension` can also supply prompt `sections`, `hooks`, `wraps`, and `tasks`.
Replacing an installed extension keeps its position. A running call keeps its selected
code; the next call uses the new code (example 31).

For busy conversations, input defaults to a follow-up. `.steer` joins the run after
the tool round; `.reject` rejects busy admission. Writes append without a model call.
Example 20 checks steering, follow-ups, and queued withdrawal. Custom tasks can wait
for owned children with `.failFast` or `.allSettled`; example 24 checks fail-fast,
abort propagation, and restart.

## Watching

A watch starts with its current value. `start` receives subsequent committed frames;
it does not send that initial value again. This checked snippet uses `root` and
`context` from an open Harness:

```swift
import Synchronization

let observed = Mutex<[ConversationView]>([])
let watch = try await root.watch(context: context)
let initial = watch.value
try watch.start { value, ops, _ in
    // A UI can render value. A remote observer can apply the exact ops.
    observed.withLock { $0.append(value) }
    print(ops.count)
}

// When observation ends:
_ = await watch.stop()
```

Callbacks are async, Sendable, and serial for each watch. The operations are the exact
committed Chord operations. A slow watch holds at most 100 pending frames; overflow
replaces them with a current snapshot. A late observer starts at current state
(example 21). `viewState` supplies a read-only attached Chord state; call `dispose`
when finished. `watchEvents` and task-graph observation supply other committed views.
A watch is not an exact submission receipt; use `Submission.wait` for that outcome.

## Storage

| Backend | Persistence | Status in this slice |
| --- | --- | --- |
| `MemoryStorage` | In memory | Integration and storage-conformance tests |
| `SqliteStorage.open(path:)` | SQLite file, or `:memory:` | Reopen, recovery, migration, and conformance tests |
| Custom `DurableStorage` | Host-defined | Protocol and reusable storage-conformance cases |
| `JsonlStorage.open(directory:)` | Recoverable JSONL files | Reopen and conformance tests; coding-tools example |
| Encrypted storage | Files | Outside this slice |

SQLite uses the Apple SDK library and requires SQLite 3.37 or later. The port reads
the upstream SQLite schema. Keep commits serialized through Session; storage preparation
alone does not reserve a future commit.

## Coding Tools

Install `CodingTools` to offer `read`, `write`, `edit`, and `bash`. The extension is
not installed by default. Each call uses the environment for its conversation.
Run this body in an async throwing function. Supply `models` and a writable
`projectDirectory`; the model can call `edit` to change a file during the turn.

```swift
let registry = createRegistry()
try registry.install(try CodingTools)
let harness = try await Harness.open(storage: MemoryStorage(),
    options: .init(models: models, registry: registry,
        env: { target, _ in LocalExecutionEnv(cwd: target.cwd ?? projectDirectory) }),
    context: .background)
let root = try await harness.root(options: .init(agent: .init(
    model: .set(.init(provider: "faux", modelId: "faux-1")),
    cwd: .set(projectDirectory))), context: .background)
let submission = try await root.submit(
    .input(content: .text("Edit notes.txt: replace world with durable.")),
    context: .background)
let settled = try await submission.wait(context: .background)
try await harness.close(context: .background)
```

`read` uses bounded memory. It reports truncation and continuation as diagnostics.
Images return `unsupported_image`. `write` keeps the supplied content. `edit`
matches every replacement against the original file and rejects missing, duplicate,
and overlapping targets. Its details contain a display diff, a unified patch, and
the first changed line. BOM and a uniform CRLF style are preserved. As upstream,
mixed line endings are converted to the first detected style. Unchanged fuzzy
match lines keep their quotes, spaces, and Unicode characters.

`bash` streams raw output. The harness keeps its tail; the environment saves full
output to a spill file when needed. The host owns these spill files. On iOS,
`LocalExecutionEnv` returns `shellUnavailable`, which the harness converts to an
error result. A mobile host can offer only the three file tools:

```swift
try await root.configure(change: .init(tools: .set(.exact([
    createReadTool(), createWriteTool(), createEditTool()
]))), context: .background)
```

The factories and `CodingTools` are throwing Swift values because tool schemas
are checked at construction. `BashToolOptions.prepare` returns a `BashExecution`
value with the command, cwd, environment variables, and inheritance choice for
that call. Mutations of one canonical path in one environment ID run in order.
This queue does not lock files against shell commands or other processes.

## Swift Differences and Scope

- Typed IDs, enums, Optional values, typed errors, and Codable/Sendable models replace
  TypeScript brands, unions, `undefined`, and dynamic JSON casts. Some invalid inputs
  reject at decoding. IDs and sequences stay in the JavaScript safe integer range.
- Chord drafts use explicit `JSONDraft` methods, not JavaScript proxies. Swift values
  replace freeze/clone and reference-identity rules. Equal event document values can
  be silent. Tool content mutation counts as replacement for retained-content tracking.
- Swift String cannot hold lone UTF-16 surrogates. Strict JSON parsing rejects them;
  a compaction text cut through a surrogate pair uses a replacement character.
  Integer structural arguments omit JavaScript coercion and sparse-array behaviors.
- Public observation listeners run asynchronously. Different subscribers can run at
  the same time. Source forwarding is synchronous; callbacks remain serial per watch.
  Chord's default observation error handler ignores errors. Disposal is nonthrowing.
- Cancellation reasons are Swift Error values. Contexts are values; keys have object
  identity. Abort listeners have independent registration tokens. Listeners added
  after abort do not run. Swift task cancellation is bridged to Chord cancellation.
- Tool schemas are explicit JSON objects; typed `defineTool` also decodes arguments.
  Application metadata is stored separately from tool values. Hook APIs follow the
  declared upstream API, not extra members on its JavaScript runtime object.
- `DurableModels` and live `HarnessSettingsProvider` are injected services. Fake models
  are per instance. Expected file/command failures are Result values from a host
  `ExecutionEnv`. The local file environment, macOS shell, and coding tools are
  included. CLI and TUI code is outside this library.
- Swift AI token estimation and validation retain the existing port's JSON formatting
  and error-wording differences. Copy/session rejection errors omit JavaScript cause
  chains. Snapshot decoding has a typed failure boundary.

Upstream examples 00–15, 17, and 20–31 have Swift integration tests with assertions.
Examples 16, 18, and 19 need real-provider setup or CLI modes and remain outside
this library slice. The compile-only spec-usage test checks the
public Swift API shapes and marks the TypeScript-only forms.

The upstream [spec at v1.1.0](https://github.com/earendil-works/pi/blob/v1.1.0/packages/durable/docs/spec.md)
is the design reference. This README describes the tested Swift surface. It does not
promise a stable API or JavaScript object identity.
