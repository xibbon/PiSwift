import Foundation
import PiSwiftAI
import PiSwiftAgent

public enum ModelThinkingSuffix: Sendable {
    case none
    case strict
    case lenient
}

public struct ModelReferenceRequest: Sendable {
    public var text: String
    public var provider: String?
    public var thinkingSuffix: ModelThinkingSuffix
    public var fuzzy: Bool

    public init(text: String, provider: String? = nil, thinkingSuffix: ModelThinkingSuffix = .strict, fuzzy: Bool = true) {
        self.text = text
        self.provider = provider
        self.thinkingSuffix = thinkingSuffix
        self.fuzzy = fuzzy
    }
}

public struct ModelReferenceTarget: Sendable {
    public let provider: String
    public let providerModels: [Model]
    public let modelText: String
    public let modelId: String
    public let thinkingLevel: ThinkingLevel?
}

public enum ModelReferenceResult: Sendable {
    case resolved(model: Model, thinkingLevel: ThinkingLevel?, warning: String?)
    case ambiguous(candidates: [Model], usableCount: Int, thinkingLevel: ThinkingLevel?, warning: String?)
    case notFound(target: ModelReferenceTarget?)

    public enum Status: Sendable {
        case resolved
        case ambiguous
        case notFound
    }

    public var status: Status {
        switch self {
        case .resolved: .resolved
        case .ambiguous: .ambiguous
        case .notFound: .notFound
        }
    }

    public var model: Model? {
        if case .resolved(let model, _, _) = self { return model }
        return nil
    }

    public var candidates: [Model] {
        if case .ambiguous(let candidates, _, _, _) = self { return candidates }
        return []
    }

    public var usableCount: Int {
        if case .ambiguous(_, let count, _, _) = self { return count }
        return 0
    }

    public var thinkingLevel: ThinkingLevel? {
        switch self {
        case .resolved(_, let level, _), .ambiguous(_, _, let level, _): level
        case .notFound: nil
        }
    }

    public var warning: String? {
        switch self {
        case .resolved(_, _, let warning), .ambiguous(_, _, _, let warning): warning
        case .notFound: nil
        }
    }

    public var target: ModelReferenceTarget? {
        if case .notFound(let target) = self { return target }
        return nil
    }

    fileprivate func withThinking(_ level: ThinkingLevel?, warning: String?) -> Self {
        switch self {
        case .resolved(let model, _, _): .resolved(model: model, thinkingLevel: level, warning: warning)
        case .ambiguous(let candidates, let count, _, _):
            .ambiguous(candidates: candidates, usableCount: count, thinkingLevel: level, warning: warning)
        case .notFound: self
        }
    }
}

func splitModelThinkingSuffix(_ text: String) -> (base: String, thinkingLevel: ThinkingLevel)? {
    guard let colon = text.lastIndex(of: ":"),
          let level = ThinkingLevel(rawValue: String(text[text.index(after: colon)...])) else { return nil }
    return (String(text[..<colon]), level)
}

private func splitProviderPrefix(_ text: String, models: [Model]) -> (provider: String, modelText: String)? {
    guard let slash = text.firstIndex(of: "/") else { return nil }
    let prefix = text[..<slash].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let modelText = text[text.index(after: slash)...].trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prefix.isEmpty, !modelText.isEmpty,
          let provider = models.first(where: { $0.provider.lowercased() == prefix })?.provider else { return nil }
    return (provider, modelText)
}

/// Collect candidates before a provider is selected. A unique match needs no stored credentials.
public func resolveModelReference(
    _ request: ModelReferenceRequest,
    _ models: [Model],
    usable: (String) -> Bool
) -> ModelReferenceResult {
    let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return .notFound(target: nil) }
    let constraint = request.provider?.lowercased()
    let pool = constraint?.isEmpty == false ? models.filter { $0.provider.lowercased() == constraint } : models
    let result = resolveReferenceText(text, request: request, pool: pool, usable: usable)
    guard result.status == .notFound else { return result }

    let split = splitProviderPrefix(text, models: pool)
    let anchor = constraint?.isEmpty == false ? pool.first : pool.first { $0.provider == split?.provider }
    guard let anchor else { return result }
    let modelText = split?.modelText ?? text
    let suffix = request.thinkingSuffix == .none ? nil : splitModelThinkingSuffix(modelText)
    return .notFound(target: ModelReferenceTarget(
        provider: anchor.provider,
        providerModels: pool.filter { $0.provider == anchor.provider },
        modelText: modelText,
        modelId: suffix?.base ?? modelText,
        thinkingLevel: suffix?.thinkingLevel
    ))
}

/// Find an exact catalog reference. Do not parse suffixes or use fuzzy matching.
public func findExactModelReferenceMatch(_ modelReference: String, _ models: [Model]) -> Model? {
    resolveModelReference(
        ModelReferenceRequest(text: modelReference, thinkingSuffix: .none, fuzzy: false), models, usable: { _ in true }
    ).model
}

/// Find catalog models only within the supplied credential-bearing providers.
/// Each provider is checked separately, as required for credential printing.
public func resolveCredentialPrintModels(_ modelReference: String, providers: [String], availableModels: [Model]) -> [Model] {
    providers.compactMap { provider in
        resolveModelReference(
            ModelReferenceRequest(text: modelReference, provider: provider, thinkingSuffix: .strict, fuzzy: true),
            availableModels,
            usable: { _ in true }
        ).model
    }
}

private func resolveReferenceText(
    _ text: String, request: ModelReferenceRequest, pool: [Model], usable: (String) -> Bool
) -> ModelReferenceResult {
    if let reference = selectReference(text, pool: pool, fuzzy: request.fuzzy, usable: usable) { return reference }
    if request.fuzzy, let fuzzy = selectFuzzy(fuzzyMatches(text, models: pool), usable: usable) { return fuzzy }
    guard request.thinkingSuffix != .none else { return .notFound(target: nil) }
    if let thinking = splitModelThinkingSuffix(text) {
        let inner = resolveReferenceText(thinking.base, request: request, pool: pool, usable: usable)
        return inner.withThinking(inner.warning == nil ? thinking.thinkingLevel : nil, warning: inner.warning)
    }
    guard request.thinkingSuffix == .lenient, let colon = text.lastIndex(of: ":") else { return .notFound(target: nil) }
    let suffix = String(text[text.index(after: colon)...])
    let inner = resolveReferenceText(String(text[..<colon]), request: request, pool: pool, usable: usable)
    return inner.withThinking(nil, warning: "Invalid thinking level \"\(suffix)\" in pattern \"\(text)\". Using default instead.")
}

private func selectReference(_ text: String, pool: [Model], fuzzy: Bool, usable: (String) -> Bool) -> ModelReferenceResult? {
    let raw = pool.filter { $0.id.lowercased() == text.lowercased() }
    var named: Model?
    if let split = splitProviderPrefix(text, models: pool) {
        let providerModels = pool.filter { $0.provider == split.provider }
        named = providerModels.first { $0.id.lowercased() == split.modelText.lowercased() }
            ?? raw.first { $0.provider == split.provider }
            ?? (fuzzy ? bestFuzzyMatch(fuzzyMatches(split.modelText, models: providerModels)) : nil)
    }
    let others = raw.filter { model in named.map { !modelsAreEqual(model, $0) } ?? true }
    let candidates = named.map { [$0] + others } ?? others
    guard let first = candidates.first else { return nil }
    if Set(candidates.map(\.provider)).count == 1 { return .resolved(model: first, thinkingLevel: nil, warning: nil) }
    if let named, usable(named.provider) { return .resolved(model: named, thinkingLevel: nil, warning: nil) }
    let usableOthers = others.filter { usable($0.provider) }
    if usableOthers.count == 1 { return .resolved(model: usableOthers[0], thinkingLevel: nil, warning: nil) }
    if usableOthers.isEmpty, let named { return .resolved(model: named, thinkingLevel: nil, warning: nil) }
    return .ambiguous(candidates: candidates, usableCount: usableOthers.count, thinkingLevel: nil, warning: nil)
}

private func fuzzyMatches(_ text: String, models: [Model]) -> [Model] {
    let lower = text.lowercased()
    return models.filter { $0.id.lowercased().contains(lower) || $0.name.lowercased().contains(lower) }
}

private func selectFuzzy(_ matches: [Model], usable: (String) -> Bool) -> ModelReferenceResult? {
    let usableMatches = Set(matches.map(\.provider)).count > 1 ? matches.filter { usable($0.provider) } : []
    let pool = usableMatches.isEmpty ? matches : usableMatches
    guard let best = bestFuzzyMatch(pool) else { return nil }
    let tied = pool.filter { $0.id == best.id }
    if Set(tied.map(\.provider)).count == 1 { return .resolved(model: best, thinkingLevel: nil, warning: nil) }
    return .ambiguous(candidates: tied, usableCount: usableMatches.isEmpty ? 0 : tied.count, thinkingLevel: nil, warning: nil)
}

private func bestFuzzyMatch(_ matches: [Model]) -> Model? {
    let aliases = matches.filter { isModelAlias($0.id) }
    return (aliases.isEmpty ? matches : aliases).sorted { $0.id.localizedCompare($1.id) == .orderedDescending }.first
}

private func isModelAlias(_ id: String) -> Bool {
    id.hasSuffix("-latest") || id.range(of: "-[0-9]{8}$", options: .regularExpression) == nil
}
