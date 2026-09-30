/// Text copied from pi-mono v0.99.1. Keep line breaks exact.
public let mcpTypescriptPreamble = #"""
type Role = "user" | "assistant";
type MetaObject = Record<string, unknown>;
type Annotations = {
  audience?: Role[];
  priority?: number;
  lastModified?: string;
};
type Icon = {
  src: string;
  mimeType?: string;
  sizes?: string[];
  theme?: "light" | "dark";
};
type TextResourceContents = {
  uri: string;
  mimeType?: string;
  _meta?: MetaObject;
  text: string;
};
type BlobResourceContents = {
  uri: string;
  mimeType?: string;
  _meta?: MetaObject;
  blob: string;
};
type TextContent = {
  type: "text";
  text: string;
  annotations?: Annotations;
  _meta?: MetaObject;
};
type ImageContent = {
  type: "image";
  data: string;
  mimeType: string;
  annotations?: Annotations;
  _meta?: MetaObject;
};
type AudioContent = {
  type: "audio";
  data: string;
  mimeType: string;
  annotations?: Annotations;
  _meta?: MetaObject;
};
type ResourceLink = {
  icons?: Icon[];
  name: string;
  title?: string;
  uri: string;
  description?: string;
  mimeType?: string;
  annotations?: Annotations;
  size?: number;
  _meta?: MetaObject;
  type: "resource_link";
};
type EmbeddedResource = {
  type: "resource";
  resource: TextResourceContents | BlobResourceContents;
  annotations?: Annotations;
  _meta?: MetaObject;
};
type ContentBlock =
  | TextContent
  | ImageContent
  | AudioContent
  | ResourceLink
  | EmbeddedResource;
type CallToolResult<TStructured = { [key: string]: unknown }> = {
  _meta?: MetaObject;
  content: ContentBlock[];
  isError?: boolean;
  structuredContent?: TStructured;
  [key: string]: unknown;
};
"""#

public let codemodeDescriptionIntro = #"""
Run JavaScript code to orchestrate/compose tool calls
- Evaluates the provided JavaScript code in a fresh QuickJS sandbox as the body of an async function: top-level `await` and `return` work.
- All nested tools are available on the global `tools` object, for example `await tools.read(...)`. Tool names are exposed as normalized JavaScript identifiers, for example `await tools.mcp__ologs__get_profile(...)`.
- Nested tool methods take an object as their input argument.
- Nested tools return either an object or a string, based on the description.
- A nested tool call that fails, is blocked, or gets invalid arguments rejects with an Error carrying the tool's error text.
- Runs raw JavaScript -- no Node, no file system, no network access, no timers.
- Accepts raw JavaScript source text, not JSON, quoted strings, or markdown code fences.
- You may optionally start the tool input with a first line like `// @options: {"max_output_tokens": 1000, "timeout_ms": 60000}`.
- `max_output_tokens` sets the token budget for the script's output. Defaults to 10000 tokens.
- `timeout_ms` sets a hard deadline for the whole script. By default there is none.
- When the JS code is fully evaluated, calls that are still running are cancelled and unawaited promises are silently discarded.
- Tool calls are real and have side effects. If the script fails partway, earlier calls are not undone.
- Scripts have a 256 MB memory limit; exceeding it throws `InternalError: out of memory`. Filter or aggregate large data instead of accumulating it.

- Global helpers:
- `exit()`: Immediately ends the current script successfully (like an early return from the top level).
- `text(value: string | number | boolean | undefined | null)`: Appends a text item. Non-string values are stringified with `JSON.stringify(...)` when possible.
- `image(imageUrlOrItem: string | { image_url: string } | ImageContent)`: Appends an image item. `image_url` should be a base64-encoded `data:` URL. To forward an MCP tool image, pass an individual `ImageContent` block from `result.content`, for example `image(result.content[0])`.
- `store(key: string, value: any)`: stores a serializable value under a string key for later `codemode` calls in the same session. Storing `undefined` deletes the key. Writes are kept only if the script succeeds.
- `load(key: string)`: returns the stored value for a string key, or `undefined` if it is missing.
- `ALL_TOOLS`: metadata for the enabled nested tools as `{ name, description }` entries.
- `searchTools(query: string, options?: { limit?: number; namespace?: string })`: resolves to the nested tools that best match the query (BM25, default limit 8), as `{ name, description }` entries like `ALL_TOOLS`.
- `describeTool(name: string)`: resolves to the description and declaration of a nested tool, or `undefined`.
- `console.log(...)` and the other `console` methods append a text item like `text()`.
- `return value` at the top level appends the value like `text()`.
"""#

public let codemodeModelTypes = #"""
type ModelType = "chat" | "image" | "classifier";
/** A model catalog entry. `provider` and `id` identify it; the other fields depend on the type. */
interface ModelInfo {
  type?: ModelType;
  provider: string;
  id: string;
  name: string;
  api: string;
  input: ("text" | "image")[];
  contextWindow?: number;
  [key: string]: unknown;
}
type ClassifierQuestion =
  | { type: "choice"; instructions: string; criteria: Record<string, string> }
  | { type: "score"; instructions: string; criteria: string[] }
  | { type: "bool"; instructions: string; criteria: { true: string; false: string } };
type ClassifierAnswer =
  | { type: "choice"; choice: string; probabilities: Record<string, number>; confidence: number }
  | { type: "score"; score: number; confidence: number }
  | { type: "bool"; probability: number };
interface ClassifierContext {
  state: Record<string, unknown>;
  questions: Record<string, ClassifierQuestion>;
}
interface ClassifierResult {
  api: string;
  provider: string;
  model: string;
  answers: Record<string, ClassifierAnswer>;
  /** Set when the service reports token counts. Cost is in USD. */
  usage?: { input: number; output: number; totalTokens: number; cost: { total: number } };
  stopReason: "stop" | "error" | "aborted";
  errorMessage?: string;
  timestamp: number;
}
"""#

public let codemodeDeferredGuidance = #"""
Some deferred nested tools may be omitted from this description. They are still available on the global `tools` object and listed in `ALL_TOOLS`.
To find one, call `await searchTools(query)`, or filter `ALL_TOOLS` by `name` and `description`.
"""#

