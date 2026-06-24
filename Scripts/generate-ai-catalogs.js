#!/usr/bin/env node

const fs = require("fs");
const path = require("path");

const repoRoot = path.resolve(__dirname, "..");
const upstreamRoot = path.resolve(repoRoot, "../pi-mono/packages/ai/src");

function loadGeneratedObject(file, exportName) {
  let source = fs.readFileSync(path.join(upstreamRoot, file), "utf8");
  source = source.replace(/import[^\n]*\n/g, "");
  source = source.replace(new RegExp(`export const ${exportName} =`), "module.exports =");
  source = source.replace(/\s+as const satisfies[\s\S]*?;\s*$/, ";");
  source = source.replace(/\s+as const;\s*$/, ";");
  source = source.replace(/\s+satisfies\s+[A-Za-z0-9_<>"'|. -]+/g, "");
  const module = { exports: undefined };
  new Function("module", source)(module);
  return module.exports;
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
  if (type === "maxTokensField") {
    return value === "max_tokens" ? ".maxTokens" : ".maxCompletionTokens";
  }
  if (type === "thinkingFormat") {
    const cases = {
      openai: "openai",
      zai: "zai",
      qwen: "qwen",
      "qwen-chat-template": "qwenChatTemplate",
      openrouter: "openrouter",
      deepseek: "deepseek",
      together: "together",
      "string-thinking": "stringThinking",
      "ant-ling": "antLing",
    };
    if (!cases[value]) throw new Error(`Unknown thinkingFormat: ${value}`);
    return `.${cases[value]}`;
  }
  if (type === "cacheControlFormat") {
    return ".anthropic";
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

function compatLiteral(compat) {
  if (!compat) return undefined;
  const fields = [
    ["supportsStore", compat.supportsStore, "bool"],
    ["supportsDeveloperRole", compat.supportsDeveloperRole, "bool"],
    ["supportsReasoningEffort", compat.supportsReasoningEffort, "bool"],
    ["supportsUsageInStreaming", compat.supportsUsageInStreaming, "bool"],
    ["supportsTemperature", compat.supportsTemperature, "bool"],
    ["maxTokensField", compat.maxTokensField, "maxTokensField"],
    ["requiresToolResultName", compat.requiresToolResultName, "bool"],
    ["requiresAssistantAfterToolResult", compat.requiresAssistantAfterToolResult, "bool"],
    ["requiresThinkingAsText", compat.requiresThinkingAsText, "bool"],
    ["requiresMistralToolIds", compat.requiresMistralToolIds, "bool"],
    ["thinkingFormat", compat.thinkingFormat, "thinkingFormat"],
    ["openRouterRouting", openRouterRoutingLiteral(compat.openRouterRouting), "literal"],
    ["vercelGatewayRouting", vercelRoutingLiteral(compat.vercelGatewayRouting), "literal"],
    ["supportsStrictMode", compat.supportsStrictMode, "bool"],
    ["reasoningEffortMap", compat.reasoningEffortMap, "reasoningEffortMap"],
    ["supportsLongCacheRetention", compat.supportsLongCacheRetention, "bool"],
    ["sendSessionIdHeader", compat.sendSessionIdHeader, "bool"],
    ["supportsEagerToolInputStreaming", compat.supportsEagerToolInputStreaming, "bool"],
    ["cacheControlFormat", compat.cacheControlFormat, "cacheControlFormat"],
    ["sendSessionAffinityHeaders", compat.sendSessionAffinityHeaders, "bool"],
    ["requiresReasoningContentOnAssistantMessages", compat.requiresReasoningContentOnAssistantMessages, "bool"],
    ["supportsCacheControlOnTools", compat.supportsCacheControlOnTools, "bool"],
    ["forceAdaptiveThinking", compat.forceAdaptiveThinking, "bool"],
    ["zaiToolStream", compat.zaiToolStream, "bool"],
  ];
  const rendered = fields.flatMap(([label, value, kind]) => {
    if (value === undefined) return [];
    if (kind === "bool") return [`${label}: ${swiftBool(value)}`];
    if (kind === "literal") return [`${label}: ${value}`];
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
  const args = [
    `id: ${swiftString(model.id)}`,
    `name: ${swiftString(model.name)}`,
    `api: ${apiCase(model.api)}`,
    `provider: ${swiftString(model.provider)}`,
    `baseUrl: ${swiftString(model.baseUrl)}`,
    `reasoning: ${swiftBool(model.reasoning)}`,
    `input: ${modelInputArray(model.input)}`,
    `cost: ModelCost(input: ${model.cost.input}, output: ${model.cost.output}, cacheRead: ${model.cost.cacheRead}, cacheWrite: ${model.cost.cacheWrite})`,
    `contextWindow: ${model.contextWindow}`,
    `maxTokens: ${model.maxTokens}`,
  ];
  const headers = headersLiteral(model.headers);
  if (headers) args.push(`headers: ${headers}`);
  const compat = compatLiteral(model.compat);
  if (compat) args.push(`compat: ${compat}`);
  const thinkingMap = thinkingLevelMapLiteral(model.thinkingLevelMap);
  if (thinkingMap) args.push(`thinkingLevelMap: ${thinkingMap}`);
  return `Model(\n        ${args.join(",\n        ")}\n    )`;
}

function swiftImagesModel(model) {
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
  return `ImagesModel(\n        ${args.join(",\n        ")}\n    )`;
}

function writeModelsData(models) {
  const providers = Object.keys(models).sort();
  const lines = [
    "import Foundation",
    "",
    "// This file is auto-generated by Scripts/generate-ai-catalogs.js.",
    "// Do not edit manually.",
    "",
    "internal let ModelsData: [String: [String: Model]] = [",
    ...providers.map((provider) => `    ${swiftString(provider)}: ${providerVariableName(provider)},`),
    "]",
    "",
  ];
  for (const provider of providers) {
    const ids = Object.keys(models[provider]).sort();
    lines.push(`private let ${providerVariableName(provider)}: [String: Model] = [`);
    for (const id of ids) {
      lines.push(`    ${swiftString(id)}: ${swiftModel(models[provider][id])},`);
    }
    lines.push("]", "");
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
    "internal let ImageModelsData: [String: [String: ImagesModel]] = [",
    ...providers.map((provider) => `    ${swiftString(provider)}: ${providerVariableName(`image_${provider}`)},`),
    "]",
    "",
  ];
  for (const provider of providers) {
    const ids = Object.keys(models[provider]).sort();
    lines.push(`private let ${providerVariableName(`image_${provider}`)}: [String: ImagesModel] = [`);
    for (const id of ids) {
      lines.push(`    ${swiftString(id)}: ${swiftImagesModel(models[provider][id])},`);
    }
    lines.push("]", "");
  }
  while (lines.at(-1) === "") lines.pop();
  fs.writeFileSync(path.join(repoRoot, "Sources/PiSwiftAI/ImageModelsData.swift"), `${lines.join("\n")}\n`);
}

const models = loadGeneratedObject("models.generated.ts", "MODELS");
const imageModels = loadGeneratedObject("image-models.generated.ts", "IMAGE_MODELS");
writeModelsData(models);
writeImageModelsData(imageModels);
writeJsonFixture("upstream-models.generated.json", models);
writeJsonFixture("upstream-image-models.generated.json", imageModels);
console.log(`Generated ${Object.values(models).reduce((sum, provider) => sum + Object.keys(provider).length, 0)} text models.`);
console.log(`Generated ${Object.values(imageModels).reduce((sum, provider) => sum + Object.keys(provider).length, 0)} image models.`);
