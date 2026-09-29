#!/usr/bin/env node

const fs = require("fs");
const path = require("path");

const repoRoot = path.resolve(__dirname, "..");
const upstreamRoot = path.resolve(repoRoot, "../pi-mono/packages/ai/src");
function readUpstreamSource(file) {
  return fs.readFileSync(path.join(upstreamRoot, file), "utf8");
}

function loadCatalogs() {
  const generatedSource = readUpstreamSource("models.generated.ts");
  const imports = new Map();
  const importPattern = /^import\s*{\s*([A-Z][A-Z0-9_]*_CLASSIFIER_MODELS),\s*([A-Z][A-Z0-9_]*_IMAGE_MODELS),\s*([A-Z][A-Z0-9_]*_MODELS)\s*}\s*from\s*"(\.\/providers\/[^\"]+\.models\.ts)";?$/gm;
  for (const match of generatedSource.matchAll(importPattern)) {
    imports.set(match[4], { classifier: match[1], image: match[2], chat: match[3] });
  }
  if (imports.size === 0) throw new Error("No v6 provider imports found in models.generated.ts");

  const catalogs = { chat: {}, image: {}, classifier: {} };
  const importedProviderIds = new Set();
  for (const [providerFile, symbols] of imports) {
    const providerPath = path.join(upstreamRoot, providerFile);
    const source = readUpstreamSource(`providers/${path.basename(providerPath)}`);
    const dataPathMatch = source.match(/import values from "(\.\/data\/[^\"]+\.json)"/);
    if (!dataPathMatch) {
      throw new Error(`Could not find model data path in ${providerFile}`);
    }
    let providerId;
    for (const [type, name] of Object.entries({ chat: "Chat", image: "Image", classifier: "Classifier" })) {
      const symbol = symbols[type];
      const match = source.match(new RegExp(`export const ${symbol}:[^;]*?flatten${name}ModelCatalog\\(\\s*"([^"]+)"\\s*,\\s*values\\s*\\)`));
      if (!match) throw new Error(`Could not find ${type} wrapper ${symbol} in ${providerFile}`);
      if (providerId !== undefined && providerId !== match[1]) throw new Error(`Wrapper provider mismatch in ${providerFile}`);
      providerId = match[1];
    }
    if (importedProviderIds.has(providerId)) throw new Error(`Duplicate provider ${providerId}`);
    importedProviderIds.add(providerId);
    // Radius uses the pi-messages gateway and gateway-only model fields. PiSwift has no Radius client.
    if (providerId === "radius") continue;
    const dataPath = path.resolve(path.dirname(providerPath), dataPathMatch[1]);
    const groups = JSON.parse(fs.readFileSync(dataPath, "utf8"));
    // Upstream flattenModelCatalog takes Object.values(groups), then each group's
    // values, filters by type, and uses entry.id as the catalog key.
    catalogs.chat[providerId] = {};
    for (const group of Object.values(groups)) {
      for (const [key, entry] of Object.entries(group)) {
        if (!["chat", "image", "classifier"].includes(entry.type)) throw new Error(`Unknown model type ${entry.type} for ${providerId}/${key}`);
        if (key !== `${entry.type}:${entry.id}`) throw new Error(`Model key mismatch for ${providerId}/${key}`);
        if (entry.provider !== providerId) throw new Error(`Model provider mismatch for ${providerId}/${key}`);
        if (entry.type !== "image" && Object.hasOwn(entry, "output")) throw new Error(`Unexpected output on ${providerId}/${key}`);
        if (entry.type === "image" && !entry.output?.includes("image")) throw new Error(`Image output missing for ${providerId}/${key}`);
        (catalogs[entry.type][providerId] ??= {})[entry.id] = entry;
      }
    }
  }

  for (const [type, aggregate] of Object.entries({ chat: "MODELS", image: "IMAGE_MODELS", classifier: "CLASSIFIER_MODELS" })) {
    const match = generatedSource.match(new RegExp(`export const ${aggregate}:[\\s\\S]*?}\\s*=\\s*{([\\s\\S]*?)^};`, "m"));
    if (!match) throw new Error(`Could not find ${aggregate} aggregate assignment`);
    const entries = [...match[1].matchAll(/^\t"([^"]+)":\s*([A-Z][A-Z0-9_]*),?$/gm)];
    const expected = new Map(entries.map((entry) => [entry[1], entry[2]]));
    if (!expected.has("radius")) throw new Error(`Expected radius in ${aggregate}`);
    if (expected.size !== importedProviderIds.size || [...importedProviderIds].some((id) => !expected.has(id))) {
      throw new Error(`Provider ids differ from ${aggregate} aggregate`);
    }
    for (const [file, symbols] of imports) {
      const id = path.basename(file, ".models.ts");
      if (expected.get(id) !== symbols[type]) throw new Error(`Symbol mismatch for ${id} in ${aggregate}`);
    }
  }
  return catalogs;
}

function loadBuiltinModelDataGeneratedAt() {
  try {
    const manifestPath = path.join(upstreamRoot, "providers/data/.manifest.json");
    const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
    const milliseconds = Date.parse(manifest.generatedAt);
    return Number.isNaN(milliseconds) ? undefined : milliseconds / 1000;
  } catch {
    return undefined;
  }
}

function sortJsonValue(value) {
  if (Array.isArray(value)) return value.map(sortJsonValue);
  if (!value || typeof value !== "object") return value;
  return Object.fromEntries(
    Object.entries(value)
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([key, item]) => [key, sortJsonValue(item)])
  );
}

function writeJsonFixture(name, value) {
  const resourcesDir = path.join(repoRoot, "Tests/PiSwiftAITests/Resources");
  fs.mkdirSync(resourcesDir, { recursive: true });
  const sorted = sortJsonValue(value);
  fs.writeFileSync(path.join(resourcesDir, name), `${JSON.stringify(sorted, null, 2)}\n`);
}

function swiftString(value) {
  return JSON.stringify(value)
    .replace(/\u2028/g, "\\u2028")
    .replace(/\u2029/g, "\\u2029");
}

function swiftBool(value) {
  return value ? "true" : "false";
}

function apiCase(api) {
  const cases = {
    "openai-completions": "openAICompletions",
    "openai-responses": "openAIResponses",
    "openai-codex-responses": "openAICodexResponses",
    "azure-openai-responses": "azureOpenAIResponses",
    "anthropic-messages": "anthropicMessages",
    "bedrock-converse-stream": "bedrockConverseStream",
    "google-generative-ai": "googleGenerativeAI",
    "google-gemini-cli": "googleGeminiCli",
    "google-vertex": "googleVertex",
    "mistral-conversations": "mistralConversations",
  };
  if (!cases[api]) throw new Error(`Unknown api: ${api}`);
  return `.${cases[api]}`;
}

function imagesApiCase(api) {
  const cases = {
    "openrouter-images": "openrouterImages",
  };
  if (!cases[api]) throw new Error(`Unknown images api: ${api}`);
  return `.${cases[api]}`;
}

function classifierApiCase(api) {
  const cases = {
    "typesafe-system-one": "typesafeSystemOne",
    "cloudflare-workers-ai-system-one": "cloudflareWorkersAISystemOne",
  };
  if (!cases[api]) throw new Error(`Unknown classifier api: ${api}`);
  return `.${cases[api]}`;
}

function modelInputArray(values) {
  return `[${values.map((value) => `.${value}`).join(", ")}]`;
}

function headersLiteral(headers) {
  if (!headers) return undefined;
  const entries = Object.entries(headers).sort(([a], [b]) => a.localeCompare(b));
  if (entries.length === 0) return "[:]";
  return `[${entries.map(([key, value]) => `${swiftString(key)}: ${swiftString(value)}`).join(", ")}]`;
}

function thinkingLevelKey(level) {
  if (level === "off") return ".off";
  return `.${level}`;
}

function thinkingLevelValue(level) {
  return `.${level}`;
}

function enumValue(type, value) {
  if (type === "thinkingTokenBudgetField") {
    const cases = {thinking_token_budget: "thinkingTokenBudget", thinking_budget: "thinkingBudget", thinking_budget_tokens: "thinkingBudgetTokens"};
    if (!cases[value]) throw new Error(`Unknown thinkingTokenBudgetField: ${value}`);
    return `.${cases[value]}`;
  }
  if (type === "maxTokensField") {
    const cases = { max_tokens: "maxTokens", max_completion_tokens: "maxCompletionTokens" };
    if (!cases[value]) throw new Error(`Unknown maxTokensField: ${value}`);
    return `.${cases[value]}`;
  }
  if (type === "thinkingFormat") {
    const cases = {
      openai: "openai",
      zai: "zai",
      qwen: "qwen",
      "chat-template": "chatTemplate",
      "qwen-chat-template": "qwenChatTemplate",
      openrouter: "openrouter",
      deepseek: "deepseek",
      together: "together",
      baseten: "baseten",
      "string-thinking": "stringThinking",
      "ant-ling": "antLing",
    };
    if (!cases[value]) throw new Error(`Unknown thinkingFormat: ${value}`);
    return `.${cases[value]}`;
  }
  if (type === "cacheControlFormat") {
    if (value !== "anthropic") throw new Error(`Unknown cacheControlFormat: ${value}`);
    return ".anthropic";
  }
  if (type === "sessionAffinityFormat") {
    const cases = { "openai": "openai", "openai-nosession": "openaiNosession", "openrouter": "openrouter" };
    if (!cases[value]) throw new Error(`Unknown sessionAffinityFormat: ${value}`);
    return `.${cases[value]}`;
  }
  throw new Error(`Unknown enum field: ${type}`);
}

function routingSortLiteral(value) {
  if (value == null) return "nil";
  if (typeof value === "string") return `.named(${swiftString(value)})`;
  return `.structured(by: ${value.by == null ? "nil" : swiftString(value.by)}, partition: ${value.partition == null ? "nil" : swiftString(value.partition)})`;
}

function routingPriceLiteral(value) {
  if (!value) return "nil";
  return `OpenRouterRoutingPrice(prompt: ${value.prompt ?? "nil"}, completion: ${value.completion ?? "nil"}, image: ${value.image ?? "nil"}, audio: ${value.audio ?? "nil"}, request: ${value.request ?? "nil"})`;
}

function percentileLiteral(value) {
  if (value == null) return "nil";
  if (typeof value === "number") return `.scalar(${value})`;
  return `.percentiles(p50: ${value.p50 ?? "nil"}, p75: ${value.p75 ?? "nil"}, p90: ${value.p90 ?? "nil"}, p99: ${value.p99 ?? "nil"})`;
}

function openRouterRoutingLiteral(value) {
  if (!value) return undefined;
  const args = [
    ["allowFallbacks", value.allow_fallbacks],
    ["requireParameters", value.require_parameters],
    ["dataCollection", value.data_collection],
    ["zdr", value.zdr],
    ["enforceDistillableText", value.enforce_distillable_text],
    ["order", value.order],
    ["only", value.only],
    ["ignore", value.ignore],
    ["quantizations", value.quantizations],
  ];
  const rendered = args.map(([label, item]) => {
    if (item === undefined) return undefined;
    if (Array.isArray(item)) return `${label}: [${item.map(swiftString).join(", ")}]`;
    if (typeof item === "string") return `${label}: ${swiftString(item)}`;
    return `${label}: ${swiftBool(item)}`;
  }).filter(Boolean);
  if (value.sort !== undefined) rendered.push(`sort: ${routingSortLiteral(value.sort)}`);
  if (value.max_price !== undefined) rendered.push(`maxPrice: ${routingPriceLiteral(value.max_price)}`);
  if (value.preferred_min_throughput !== undefined) rendered.push(`preferredMinThroughput: ${percentileLiteral(value.preferred_min_throughput)}`);
  if (value.preferred_max_latency !== undefined) rendered.push(`preferredMaxLatency: ${percentileLiteral(value.preferred_max_latency)}`);
  return `OpenRouterRouting(${rendered.join(", ")})`;
}

function vercelRoutingLiteral(value) {
  if (!value) return undefined;
  const rendered = [];
  if (value.only !== undefined) rendered.push(`only: [${value.only.map(swiftString).join(", ")}]`);
  if (value.order !== undefined) rendered.push(`order: [${value.order.map(swiftString).join(", ")}]`);
  if (value.allow_fallbacks !== undefined) rendered.push(`allowFallbacks: ${swiftBool(value.allow_fallbacks)}`);
  return `VercelGatewayRouting(${rendered.join(", ")})`;
}

function chatTemplateKwargValueLiteral(value) {
  if (value === null) return ".null";
  if (typeof value === "string") return `.string(${swiftString(value)})`;
  if (typeof value === "number") return `.number(${value})`;
  if (typeof value === "boolean") return `.bool(${swiftBool(value)})`;
  if (value && typeof value === "object") {
    const variables = {
      "thinking.enabled": "thinkingEnabled",
      "thinking.effort": "thinkingEffort",
      "thinking.budget": "thinkingBudget",
    };
    const variable = variables[value.$var];
    if (!variable) throw new Error(`Unknown chat-template variable: ${value.$var}`);
    const omitWhenOff = value.omitWhenOff === true ? ", omitWhenOff: true" : "";
    return `.variable(.${variable}${omitWhenOff})`;
  }
  throw new Error(`Unsupported chat-template value: ${value}`);
}

function chatTemplateValuesLiteral(values) {
  const entries = Object.entries(values)
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([key, value]) => `${swiftString(key)}: ${chatTemplateKwargValueLiteral(value)}`);
  return entries.length === 0 ? "[:]" : `[${entries.join(", ")}]`;
}

function compatLiteral(compat, api) {
  if (!compat) return undefined;
  if (api === "mistral-conversations") {
    const keys = Object.keys(compat);
    if (keys.some((key) => key !== "supportsMidConvoSystemMessages")) {
      throw new Error(`Unmapped Mistral compat field: ${keys.filter((key) => key !== "supportsMidConvoSystemMessages").join(", ")}`);
    }
    return `MistralConversationsCompat(${compat.supportsMidConvoSystemMessages === undefined ? "" : `supportsMidConvoSystemMessages: ${swiftBool(compat.supportsMidConvoSystemMessages)}`})`;
  }
  const fields = [
    ["supportsStore", compat.supportsStore, "bool"],
    ["supportsDeveloperRole", compat.supportsDeveloperRole, "bool"],
    ["supportsReasoningEffort", compat.supportsReasoningEffort, "bool"],
    ["supportsUsageInStreaming", compat.supportsUsageInStreaming, "bool"],
    ["supportsFinishReason", compat.supportsFinishReason, "bool"],
    ["supportsTemperature", compat.supportsTemperature, "bool"],
    ["maxTokensField", compat.maxTokensField, "maxTokensField"],
    ["requiresToolResultName", compat.requiresToolResultName, "bool"],
    ["requiresAssistantAfterToolResult", compat.requiresAssistantAfterToolResult, "bool"],
    ["requiresThinkingAsText", compat.requiresThinkingAsText, "bool"],
    ["requiresMistralToolIds", compat.requiresMistralToolIds, "bool"],
    ["thinkingFormat", compat.thinkingFormat, "thinkingFormat"],
    ["chatTemplateKwargs", compat.chatTemplateKwargs, "chatTemplateValues"],
    ["chatTemplateArgs", compat.chatTemplateArgs, "chatTemplateValues"],
    ["openRouterRouting", openRouterRoutingLiteral(compat.openRouterRouting), "literal"],
    ["vercelGatewayRouting", vercelRoutingLiteral(compat.vercelGatewayRouting), "literal"],
    ["supportsThinkingTokenBudget", compat.supportsThinkingTokenBudget, "bool"],
    ["supportsOpenAIGrammarTools", compat.supportsOpenAIGrammarTools, "bool"],
    ["supportsMidConvoSystemMessages", compat.supportsMidConvoSystemMessages, "bool"],
    ["supportsMidConvoToolAdditions", compat.supportsMidConvoToolAdditions, "bool"],
    ["supportsMidConvoToolChanges", compat.supportsMidConvoToolChanges, "bool"],
    ["supportsStrictMode", compat.supportsStrictMode, "bool"],
    ["reasoningEffortMap", compat.reasoningEffortMap, "reasoningEffortMap"],
    ["supportsLongCacheRetention", compat.supportsLongCacheRetention, "bool"],
    ["sendSessionIdHeader", compat.sendSessionIdHeader, "bool"],
    ["supportsEagerToolInputStreaming", compat.supportsEagerToolInputStreaming, "bool"],
    ["cacheControlFormat", compat.cacheControlFormat, "cacheControlFormat"],
    ["sendSessionAffinityHeaders", compat.sendSessionAffinityHeaders, "bool"],
    ["requiresReasoningContentOnAssistantMessages", compat.requiresReasoningContentOnAssistantMessages, "bool"],
    ["supportsCacheControlOnTools", compat.supportsCacheControlOnTools, "bool"],
    ["supportsStrictTools", compat.supportsStrictTools, "bool"],
    ["forceAdaptiveThinking", compat.forceAdaptiveThinking, "bool"],
    ["zaiToolStream", compat.zaiToolStream, "bool"],
    ["allowEmptySignature", compat.allowEmptySignature, "bool"],
    ["sessionAffinityFormat", compat.sessionAffinityFormat, "sessionAffinityFormat"],
    ["supportsToolSearch", compat.supportsToolSearch, "bool"],
    ["supportsExplicitPromptCacheMode", compat.supportsExplicitPromptCacheMode, "bool"],
    ["thinkingTokenBudgetField", compat.thinkingTokenBudgetField, "thinkingTokenBudgetField"],
    ["vllmPriority", compat.vllmPriority, "literal"],
    ["supportsAdditionalTools", compat.supportsAdditionalTools, "bool"],
    ["supportsMaxOutputTokens", compat.supportsMaxOutputTokens, "bool"],
    ["supportsMidConvoEffort", compat.supportsMidConvoEffort, "bool"],
    ["allowedFallbackModels", compat.allowedFallbackModels, "fallbackModels"],
  ];
  for (const key of Object.keys(compat)) {
    if (!fields.some(([label]) => label === key)) throw new Error(`Unmapped compat field: ${key}`);
  }
  const rendered = fields.flatMap(([label, value, kind]) => {
    if (value === undefined) return [];
    if (kind === "fallbackModels") return [`${label}: [${value.map((fallback) => `AnthropicAllowedFallbackModel(provider: ${swiftString(fallback.provider)}, model: ${swiftString(fallback.model)}, cost: ${costLiteral(fallback.cost)})`).join(", ")}]`];
    if (kind === "bool") return [`${label}: ${swiftBool(value)}`];
    if (kind === "literal") return [`${label}: ${value}`];
    if (kind === "chatTemplateValues") return [`${label}: ${chatTemplateValuesLiteral(value)}`];
    if (kind === "reasoningEffortMap") {
      const entries = Object.entries(value)
        .sort(([a], [b]) => a.localeCompare(b))
        .map(([key, item]) => `${thinkingLevelValue(key)}: ${swiftString(item)}`);
      return [`${label}: [${entries.join(", ")}]`];
    }
    return [`${label}: ${enumValue(kind, value)}`];
  });
  return rendered.length === 0 ? "OpenAICompat()" : `OpenAICompat(${rendered.join(", ")})`;
}

function thinkingLevelMapLiteral(map) {
  if (!map) return undefined;
  const entries = Object.entries(map)
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([key, value]) => `${thinkingLevelKey(key)}: ${value === null ? "nil" : swiftString(value)}`);
  return `[${entries.join(", ")}]`;
}

function providerVariableName(provider) {
  return `providerModels_${provider.replace(/[^A-Za-z0-9]+/g, "_").replace(/_$/g, "").replace(/^_/g, "")}`;
}

function swiftModel(model) {
  const allowed = new Set(["type", "id", "name", "api", "provider", "baseUrl", "reasoning", "input", "inputLimits", "cost", "promptCache", "contextWindow", "maxTokens", "samplingParams", "headers", "compat", "thinkingLevelMap"]);
  for (const key of Object.keys(model)) {
    if (!allowed.has(key)) throw new Error(`Unmapped model field ${model.provider}/${model.id}: ${key}`);
  }
  if (model.type !== "chat") throw new Error(`Expected chat model ${model.provider}/${model.id}`);
  if (model.samplingParams !== undefined) throw new Error(`Unmapped samplingParams for ${model.provider}/${model.id}`);
  const cost = costLiteral(model.cost);
  const args = [
    `id: ${swiftString(model.id)}`,
    `name: ${swiftString(model.name)}`,
    `api: ${apiCase(model.api)}`,
    `provider: ${swiftString(model.provider)}`,
    `baseUrl: ${swiftString(model.baseUrl)}`,
    `reasoning: ${swiftBool(model.reasoning)}`,
    `input: ${modelInputArray(model.input)}`,
    `cost: ${cost}`,
    `contextWindow: ${model.contextWindow}`,
    `maxTokens: ${model.maxTokens}`,
  ];
  const headers = headersLiteral(model.headers);
  if (headers) args.push(`headers: ${headers}`);
  const compat = compatLiteral(model.compat, model.api);
  if (compat) args.push(`compat: ${compat}`);
  const thinkingMap = thinkingLevelMapLiteral(model.thinkingLevelMap);
  if (thinkingMap) args.push(`thinkingLevelMap: ${thinkingMap}`);
  if (model.inputLimits) args.push(`inputLimits: ${inputLimitsLiteral(model.inputLimits)}`);
  if (model.promptCache) args.push(`promptCache: ${promptCacheLiteral(model.promptCache)}`);
  return `Model(\n        ${args.join(",\n        ")}\n    )`;
}

function assertKeys(value, allowed, label) {
  for (const key of Object.keys(value)) if (!allowed.includes(key)) throw new Error(`Unmapped ${label} field: ${key}`);
}

function inputLimitsLiteral(value) {
  assertKeys(value, ["maxRequestBytes", "images"], "inputLimits");
  let images = "nil";
  if (value.images) {
    assertKeys(value.images, ["resize", "maxPerMessage", "maxPerRequest"], "inputLimits.images");
    let resize = "nil";
    if (value.images.resize) {
      const item = value.images.resize;
      assertKeys(item, ["maxWidth", "maxHeight", "maxBytes", "jpegQuality"], "inputLimits.images.resize");
      resize = `ModelImageResizeOptions(maxWidth: ${item.maxWidth ?? "nil"}, maxHeight: ${item.maxHeight ?? "nil"}, maxBytes: ${item.maxBytes ?? "nil"}, jpegQuality: ${item.jpegQuality ?? "nil"})`;
    }
    images = `ModelImageInputLimits(resize: ${resize}, maxPerMessage: ${value.images.maxPerMessage ?? "nil"}, maxPerRequest: ${value.images.maxPerRequest ?? "nil"})`;
  }
  return `ModelInputLimits(maxRequestBytes: ${value.maxRequestBytes ?? "nil"}, images: ${images})`;
}

function promptCacheLiteral(value) {
  assertKeys(value, ["short", "long"], "promptCache");
  return `ModelPromptCache(short: ${value.short ?? "nil"}, long: ${value.long ?? "nil"})`;
}

function swiftImageModel(model) {
  assertKeys(model, ["type", "id", "name", "api", "provider", "baseUrl", "input", "inputLimits", "output", "cost", "headers"], "image model");
  if (model.type !== "image") throw new Error(`Expected image model ${model.provider}/${model.id}`);
  const args = [
    `id: ${swiftString(model.id)}`,
    `name: ${swiftString(model.name)}`,
    `api: ${imagesApiCase(model.api)}`,
    `provider: ${swiftString(model.provider)}`,
    `baseUrl: ${swiftString(model.baseUrl)}`,
    `input: ${modelInputArray(model.input)}`,
    `output: ${modelInputArray(model.output)}`,
    `cost: ModelCost(input: ${model.cost.input}, output: ${model.cost.output}, cacheRead: ${model.cost.cacheRead}, cacheWrite: ${model.cost.cacheWrite})`,
  ];
  const headers = headersLiteral(model.headers);
  if (headers) args.push(`headers: ${headers}`);
  if (model.inputLimits) args.push(`inputLimits: ${inputLimitsLiteral(model.inputLimits)}`);
  return `ImageModel(\n        ${args.join(",\n        ")}\n    )`;
}

function swiftClassifierModel(model) {
  assertKeys(model, ["type", "id", "name", "api", "provider", "baseUrl", "input", "cost", "contextWindow", "headers"], "classifier model");
  if (model.type !== "classifier") throw new Error(`Expected classifier model ${model.provider}/${model.id}`);
  const args = [
    `id: ${swiftString(model.id)}`,
    `name: ${swiftString(model.name)}`,
    `api: ${classifierApiCase(model.api)}`,
    `provider: ${swiftString(model.provider)}`,
    `baseUrl: ${swiftString(model.baseUrl)}`,
    `input: ${modelInputArray(model.input)}`,
    `cost: ${costLiteral(model.cost)}`,
    `contextWindow: ${model.contextWindow}`,
  ];
  const headers = headersLiteral(model.headers);
  if (headers) args.push(`headers: ${headers}`);
  return `ClassifierModel(\n        ${args.join(",\n        ")}\n    )`;
}

function writeModelsData(models, generatedAt) {
  const providers = Object.keys(models).sort();
  const modelsPerDictionaryChunk = 100;
  const lines = [
    "import Foundation",
    "",
    "// This file is auto-generated by Scripts/generate-ai-catalogs.js.",
    "// Do not edit manually.",
    "",
    "/// Generation timestamp shared by all built-in provider catalogs (seconds since 1970).",
    `internal let builtinModelDataGeneratedAt: Double? = ${generatedAt ?? "nil"}`,
    "",
    "internal let ModelsData: [String: [String: Model]] = [",
    ...providers.map((provider) => `    ${swiftString(provider)}: ${providerVariableName(provider)},`),
    "]",
    "",
  ];
  for (const provider of providers) {
    const ids = Object.keys(models[provider]).sort();
    const variableName = providerVariableName(provider);
    if (ids.length === 0) {
      lines.push(`private let ${variableName}: [String: Model] = [:]`, "");
      continue;
    }
    const chunks = Array.from({ length: Math.ceil(ids.length / modelsPerDictionaryChunk) }, (_, index) =>
      ids.slice(index * modelsPerDictionaryChunk, (index + 1) * modelsPerDictionaryChunk)
    );
    const chunkVariableNames = chunks.map((_, index) => chunks.length === 1 ? variableName : `${variableName}_chunk${index + 1}`);
    if (chunks.length > 1) {
      const merged = chunkVariableNames.slice(1).reduce(
        (result, chunkVariableName) => `${result}.merging(${chunkVariableName}) { _, new in new }`,
        chunkVariableNames[0]
      );
      lines.push(`private let ${variableName}: [String: Model] = ${merged}`, "");
    }
    for (const [index, chunk] of chunks.entries()) {
      lines.push(`private let ${chunkVariableNames[index]}: [String: Model] = [`);
      for (const id of chunk) {
        lines.push(`    ${swiftString(id)}: ${swiftModel(models[provider][id])},`);
      }
      lines.push("]", "");
    }
  }
  while (lines.at(-1) === "") lines.pop();
  fs.writeFileSync(path.join(repoRoot, "Sources/PiSwiftAI/ModelsData.swift"), `${lines.join("\n")}\n`);
}

function writeImageModelsData(models) {
  const providers = Object.keys(models).sort();
  const lines = [
    "import Foundation",
    "",
    "// This file is auto-generated by Scripts/generate-ai-catalogs.js.",
    "// Do not edit manually.",
    "",
    "internal let ImageModelsData: [String: [String: ImageModel]] = [",
    ...providers.map((provider) => `    ${swiftString(provider)}: ${providerVariableName(`image_${provider}`)},`),
    "]",
    "",
  ];
  for (const provider of providers) {
    const ids = Object.keys(models[provider]).sort();
    lines.push(`private let ${providerVariableName(`image_${provider}`)}: [String: ImageModel] = [`);
    for (const id of ids) {
      lines.push(`    ${swiftString(id)}: ${swiftImageModel(models[provider][id])},`);
    }
    lines.push("]", "");
  }
  while (lines.at(-1) === "") lines.pop();
  fs.writeFileSync(path.join(repoRoot, "Sources/PiSwiftAI/ImageModelsData.swift"), `${lines.join("\n")}\n`);
}

function writeClassifierModelsData(models) {
  const providers = Object.keys(models).sort();
  const lines = [
    "import Foundation", "",
    "// This file is auto-generated by Scripts/generate-ai-catalogs.js.",
    "// Do not edit manually.", "",
    "internal let ClassifierModelsData: [String: [String: ClassifierModel]] = [",
    ...providers.map((provider) => `    ${swiftString(provider)}: ${providerVariableName(`classifier_${provider}`)},`),
    "]", "",
  ];
  for (const provider of providers) {
    lines.push(`private let ${providerVariableName(`classifier_${provider}`)}: [String: ClassifierModel] = [`);
    for (const id of Object.keys(models[provider]).sort()) {
      lines.push(`    ${swiftString(id)}: ${swiftClassifierModel(models[provider][id])},`);
    }
    lines.push("]", "");
  }
  while (lines.at(-1) === "") lines.pop();
  fs.writeFileSync(path.join(repoRoot, "Sources/PiSwiftAI/ClassifierModelsData.swift"), `${lines.join("\n")}\n`);
}

const catalogs = loadCatalogs();
const models = catalogs.chat;
const builtinModelDataGeneratedAt = loadBuiltinModelDataGeneratedAt();
const imageModels = catalogs.image;
const classifierModels = catalogs.classifier;
writeModelsData(models, builtinModelDataGeneratedAt);
writeImageModelsData(imageModels);
writeClassifierModelsData(classifierModels);
writeJsonFixture("upstream-models.generated.json", models);
writeJsonFixture("upstream-image-models.generated.json", imageModels);
writeJsonFixture("upstream-classifier-models.generated.json", classifierModels);
for (const [type, entries] of Object.entries(catalogs)) {
  console.log(`Generated ${Object.values(entries).reduce((sum, provider) => sum + Object.keys(provider).length, 0)} ${type === "chat" ? "text" : type} models across ${Object.keys(entries).length} providers.`);
}

function costLiteral(cost) {
  return cost.tiers?.length
    ? `ModelCost(input: ${cost.input}, output: ${cost.output}, cacheRead: ${cost.cacheRead}, cacheWrite: ${cost.cacheWrite}, tiers: [${cost.tiers.map((tier) => `ModelCostTier(inputTokensAbove: ${tier.inputTokensAbove}, input: ${tier.input}, output: ${tier.output}, cacheRead: ${tier.cacheRead}, cacheWrite: ${tier.cacheWrite})`).join(", ")}])`
    : `ModelCost(input: ${cost.input}, output: ${cost.output}, cacheRead: ${cost.cacheRead}, cacheWrite: ${cost.cacheWrite})`;
}
