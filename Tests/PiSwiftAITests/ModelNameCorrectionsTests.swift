import Foundation
import Testing
@testable import PiSwiftAI

private func modelJSONWithoutName(_ model: Model) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let data = try encoder.encode(model)
    var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["name"] = nil
    let canonical = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
    return String(decoding: canonical, as: UTF8.self)
}

@Test func modelNameCorrectionsApplyAndKeepOtherFields() throws {
    #expect(modelNameCorrections.count == 10)
    for correction in modelNameCorrections {
        let raw = try #require(ModelsData[correction.provider]?[correction.id])
        let model = try #require(getModel(provider: correction.provider, modelId: correction.id))
        #expect(model.name == correction.name)
        #expect(model.id == raw.id)
        #expect(model.provider == raw.provider)
        #expect(try modelJSONWithoutName(model) == modelJSONWithoutName(raw), "Changed fields for \(correction.provider)/\(correction.id)")
    }
}

/// When this fails, upstream changed a name. Remove or update the row.
@Test func modelNameCorrectionsMatchUpstream() throws {
    for correction in modelNameCorrections {
        let raw = try #require(ModelsData[correction.provider]?[correction.id], "Unknown model \(correction.provider)/\(correction.id)")
        #expect(raw.name == correction.upstreamName, "Stale correction for \(correction.provider)/\(correction.id)")
    }
}

@Test func builtinVersionedClaudeNamesDoNotSayLatest() {
    let versioned = /Claude .*[0-9]/
    for provider in getProviders() {
        for model in getModels(provider: provider) where model.name.contains(versioned) {
            #expect(!model.name.hasSuffix("(latest)"), "\(provider.rawValue)/\(model.id) is named \(model.name)")
        }
    }
}

@Test func correctedProvidersHaveUniqueModelNames() {
    for provider in ["anthropic", "cloudflare-ai-gateway", "github-copilot"] {
        let names = getModelsOfType(.chat, provider: provider).map { $0.catalog.name }
        let duplicates = Dictionary(grouping: names, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
        #expect(duplicates.isEmpty, "Duplicate names in \(provider): \(duplicates)")
    }
}

@Test func rollingAliasesKeepUpstreamNames() throws {
    let aliases = [
        ("mistral", "mistral-large-latest"),
        ("openai", "gpt-5-chat-latest"),
        ("google", "gemini-flash-latest"),
        ("openrouter", "~anthropic/claude-opus-latest"),
    ]
    for (provider, id) in aliases {
        let raw = try #require(ModelsData[provider]?[id], "Unknown model \(provider)/\(id)")
        #expect(getModel(provider: provider, modelId: id)?.name == raw.name)
    }
}

@Test func modelNameCorrectionNeedsExactUpstreamName() {
    #expect(correctedModelName(provider: "anthropic", id: "claude-opus-4-5", name: "Claude Opus 4.5 (latest)") == "Claude Opus 4.5")
    #expect(correctedModelName(provider: "anthropic", id: "claude-opus-4-5", name: "Claude Opus 4.5 (newest)") == "Claude Opus 4.5 (newest)")
    #expect(correctedModelName(provider: "openrouter", id: "claude-opus-4-5", name: "Claude Opus 4.5 (latest)") == "Claude Opus 4.5 (latest)")
}
