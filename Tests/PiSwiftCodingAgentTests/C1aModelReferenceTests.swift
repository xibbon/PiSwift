import Testing
import PiSwiftAI
import PiSwiftCodingAgent

private func referenceModel(_ provider: String, _ id: String, name: String? = nil) -> Model {
    Model(
        id: id, name: name ?? id, api: .openAICompletions, provider: provider,
        baseUrl: "https://example.invalid", reasoning: true, input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 128_000, maxTokens: 8192
    )
}

private func modelReference(_ model: Model) -> String {
    "\(model.provider)/\(model.id)"
}

private let referenceCatalog: [Model] = [
    referenceModel("anthropic", "claude-sonnet-4-5"),
    referenceModel("anthropic", "claude-sonnet-4-5-20250929"),
    referenceModel("anthropic", "claude-opus-4-8"),
    referenceModel("anthropic", "exact"),
    referenceModel("anthropic", "shared-pro"),
    referenceModel("openai", "gpt-4o"),
    referenceModel("openrouter", "qwen/qwen3-coder:exacto"),
    referenceModel("openrouter", "openai/gpt-4o:extended"),
    referenceModel("gw-a", "shared"),
    referenceModel("gw-a", "anthropic/future"),
    referenceModel("gw-a", "anthropic/exact"),
    referenceModel("gw-a", "anthropic/claude-opus-4.8"),
    referenceModel("gw-a", "anthropic/claude-opus"),
    referenceModel("gw-b", "shared"),
    referenceModel("gw-b", "anthropic/future"),
    referenceModel("gw-b", "claude-opus-4-8"),
    referenceModel("gw-b", "gw-b/free"),
    referenceModel("gw-b", "zz:free"),
]

private struct ReferenceCase: Sendable, CustomTestStringConvertible {
    let name: String
    let request: ModelReferenceRequest
    let usable: Set<String>
    let model: String?
    let candidates: [String]
    let usableCount: Int
    let thinking: String?
    let warning: String?

    var testDescription: String { name }

    init(
        _ name: String, _ text: String, provider: String? = nil,
        thinkingSuffix: ModelThinkingSuffix = .strict, fuzzy: Bool = true,
        usable: [String] = [], model: String? = nil, candidates: [String] = [],
        usableCount: Int = 0, thinking: String? = nil, warning: String? = nil
    ) {
        self.name = name
        self.request = ModelReferenceRequest(
            text: text, provider: provider, thinkingSuffix: thinkingSuffix, fuzzy: fuzzy
        )
        self.usable = Set(usable)
        self.model = model
        self.candidates = candidates
        self.usableCount = usableCount
        self.thinking = thinking
        self.warning = warning
    }
}

// These cases come from the v1.3.0 model resolver tests.
private let referenceCases: [ReferenceCase] = [
    .init("exact id", "claude-sonnet-4-5", model: "anthropic/claude-sonnet-4-5"),
    .init("exact id is case-insensitive", "GPT-4O", model: "openai/gpt-4o"),
    .init("fuzzy prefers aliases over dated ids", "sonnet", model: "anthropic/claude-sonnet-4-5"),
    .init("thinking suffix", "sonnet:high", model: "anthropic/claude-sonnet-4-5", thinking: "high"),
    .init("colon in a literal id is not a thinking suffix", "qwen/qwen3-coder:exacto", model: "openrouter/qwen/qwen3-coder:exacto"),
    .init("provider prefix, colon id, and thinking suffix", "openrouter/qwen/qwen3-coder:exacto:high", model: "openrouter/qwen/qwen3-coder:exacto", thinking: "high"),
    .init("raw id wins when the provider prefix names no matching model", "openai/gpt-4o:extended", model: "openrouter/openai/gpt-4o:extended"),
    .init("fuzzy searches the prefixed provider first", "openrouter/qwen", model: "openrouter/qwen/qwen3-coder:exacto"),
    .init("strict keeps an invalid suffix in the id", "gpt-4o:random"),
    .init("lenient drops an invalid suffix with a warning", "gpt-4o:random", thinkingSuffix: .lenient, model: "openai/gpt-4o", warning: "Invalid thinking level \"random\" in pattern \"gpt-4o:random\". Using default instead."),
    .init("lenient invalid outer suffix discards the inner thinking level", "qwen/qwen3-coder:exacto:high:random", thinkingSuffix: .lenient, model: "openrouter/qwen/qwen3-coder:exacto", warning: "Invalid thinking level \"random\" in pattern \"qwen/qwen3-coder:exacto:high:random\". Using default instead."),
    .init("none keeps the suffix in the id", "gpt-4o:high", thinkingSuffix: .none),
    .init("exact-only skips fuzzy matches", "sonnet", fuzzy: false),
    .init("empty text", "  "),
    .init("sole usable provider wins", "shared", usable: ["gw-b"], model: "gw-b/shared"),
    .init("no usable provider is ambiguous instead of falling through to fuzzy", "shared", candidates: ["gw-a/shared", "gw-b/shared"], usableCount: 0),
    .init("several usable providers are ambiguous", "shared", usable: ["gw-a", "gw-b"], candidates: ["gw-a/shared", "gw-b/shared"], usableCount: 2),
    .init("thinking suffix does not change provider selection", "shared:high", usable: ["gw-b"], model: "gw-b/shared", thinking: "high"),
    .init("thinking suffix does not bypass ambiguity", "shared:high", usable: ["gw-a", "gw-b"], candidates: ["gw-a/shared", "gw-b/shared"], usableCount: 2, thinking: "high"),
    .init("provider prefix without a direct model selects the usable raw id", "anthropic/future", usable: ["gw-b"], model: "gw-b/anthropic/future"),
    .init("usable qualified match beats a usable raw id", "anthropic/exact", usable: ["anthropic", "gw-a"], model: "anthropic/exact"),
    .init("usable raw id beats an unusable qualified match", "anthropic/exact", usable: ["gw-a"], model: "gw-a/anthropic/exact"),
    .init("unusable qualified match is kept when nothing is usable", "anthropic/exact", model: "anthropic/exact"),
    .init("named provider's usable fuzzy match beats a raw id elsewhere", "anthropic/claude-opus", usable: ["anthropic"], model: "anthropic/claude-opus-4-8"),
    .init("usable raw id beats the named provider's unusable fuzzy match", "anthropic/claude-opus", usable: ["gw-a"], model: "gw-a/anthropic/claude-opus"),
    .init("named provider's fuzzy match is kept when nothing is usable", "anthropic/claude-opus", model: "anthropic/claude-opus-4-8"),
    .init("named provider's literal id beats its fuzzy matches", "gw-b/free", model: "gw-b/gw-b/free"),
    .init("fuzzy prefers usable providers", "opus", usable: ["gw-a"], model: "gw-a/anthropic/claude-opus-4.8"),
    .init("fuzzy id tie across usable providers is ambiguous", "opus", usable: ["anthropic", "gw-a", "gw-b"], candidates: ["anthropic/claude-opus-4-8", "gw-b/claude-opus-4-8"], usableCount: 2),
    .init("fuzzy id tie resolves to the sole usable provider", "opus", usable: ["anthropic"], model: "anthropic/claude-opus-4-8"),
    .init("explicit provider ignores usable providers elsewhere", "shared", provider: "gw-a", usable: ["gw-b"], model: "gw-a/shared"),
    .init("explicit provider accepts its own prefix", "GW-B/shared", provider: "gw-b", model: "gw-b/shared"),
    .init("explicit provider allows fuzzy matches", "4o", provider: "openai", model: "openai/gpt-4o"),
    .init("explicit provider never leaves the provider", "gpt-4o", provider: "gw-a"),
]

@Suite(.timeLimit(.minutes(1)))
struct C1aModelReferenceTests {
    @Test(arguments: referenceCases)
    fileprivate func upstreamReferenceCase(_ testCase: ReferenceCase) {
        for models in [referenceCatalog, Array(referenceCatalog.reversed())] {
            let result = resolveModelReference(testCase.request, models, usable: testCase.usable.contains)
            if let expected = testCase.model {
                #expect(result.status == .resolved)
                #expect(result.model.map(modelReference) == expected)
            } else if !testCase.candidates.isEmpty {
                #expect(result.status == .ambiguous)
                #expect(result.candidates.map(modelReference).sorted() == testCase.candidates)
                #expect(result.usableCount == testCase.usableCount)
                #expect(result.model == nil)
            } else {
                #expect(result.status == .notFound)
                #expect(result.model == nil)
            }
            #expect(result.thinkingLevel?.rawValue == testCase.thinking)
            #expect(result.warning == testCase.warning)
        }
    }

    @Test(arguments: ["off", "minimal", "low", "medium", "high", "xhigh", "max"])
    func allThinkingLevels(_ level: String) {
        for models in [referenceCatalog, Array(referenceCatalog.reversed())] {
            let result = resolveModelReference(
                ModelReferenceRequest(text: "openrouter/qwen/qwen3-coder:exacto:\(level)"),
                models, usable: { _ in false }
            )
            #expect(result.status == .resolved)
            #expect(result.model?.id == "qwen/qwen3-coder:exacto")
            #expect(result.thinkingLevel?.rawValue == level)
            #expect(result.warning == nil)
        }
    }

    @Test func targetRetainsProviderAndModelText() throws {
        for models in [referenceCatalog, Array(referenceCatalog.reversed())] {
            let result = resolveModelReference(
                ModelReferenceRequest(text: "  OPENROUTER/ custom/future:high  "),
                models, usable: { _ in true }
            )
            #expect(result.status == .notFound)
            let target = try #require(result.target)
            #expect(target.provider == "openrouter")
            #expect(target.modelText == "custom/future:high")
            #expect(target.modelId == "custom/future")
            #expect(target.thinkingLevel == .high)
            #expect(target.providerModels.map(modelReference).sorted() == [
                "openrouter/openai/gpt-4o:extended", "openrouter/qwen/qwen3-coder:exacto",
            ])
        }
    }

    @Test func explicitProviderTargetAndSuffixModes() throws {
        for models in [referenceCatalog, Array(referenceCatalog.reversed())] {
            for mode in [ModelThinkingSuffix.strict, .lenient, .none] {
                for suffix in ["high", "banana"] {
                    let result = resolveModelReference(
                        ModelReferenceRequest(
                            text: "missing/future:\(suffix)", provider: "OPENAI", thinkingSuffix: mode
                        ), models, usable: { _ in true }
                    )
                    #expect(result.status == .notFound)
                    let target = try #require(result.target)
                    #expect(target.provider == "openai")
                    #expect(target.providerModels.map(modelReference) == ["openai/gpt-4o"])
                    #expect(target.modelText == "missing/future:\(suffix)")
                    let stripsSuffix = mode != .none && suffix == "high"
                    #expect(target.modelId == (stripsSuffix ? "missing/future" : "missing/future:\(suffix)"))
                    #expect(target.thinkingLevel?.rawValue == (stripsSuffix ? "high" : nil))
                    #expect(result.warning == nil)
                }
            }
        }
    }

    @Test func missingTargetWithoutKnownProvider() {
        for request in [
            ModelReferenceRequest(text: "missing"),
            ModelReferenceRequest(text: "unknown/missing:high"),
            ModelReferenceRequest(text: "missing", provider: "unknown"),
            ModelReferenceRequest(text: "  ", provider: "openai"),
        ] {
            let result = resolveModelReference(request, referenceCatalog, usable: { _ in true })
            #expect(result.status == .notFound)
            #expect(result.target == nil)
        }
        let empty = resolveModelReference(
            ModelReferenceRequest(text: "openai/missing:high", provider: "openai"),
            [], usable: { _ in true }
        )
        #expect(empty.status == .notFound)
        #expect(empty.target == nil)
    }

    @Test func fuzzyUsesAliasesThenLatestAndNames() {
        let catalogs: [([Model], String, String)] = [
            ([referenceModel("p", "series-20260101"), referenceModel("p", "series-20260201"),
              referenceModel("p", "series")], "serie", "series"),
            ([referenceModel("p", "series-20260101"), referenceModel("p", "series-20260201"),
              referenceModel("p", "series-latest")], "series", "series-latest"),
            ([referenceModel("p", "series-20260101"), referenceModel("p", "series-20260201")],
             "series", "series-20260201"),
            ([referenceModel("p", "series-a"), referenceModel("p", "series-b")], "series", "series-b"),
            ([referenceModel("p", "opaque-id", name: "Friendly Model")], "FRIENDLY", "opaque-id"),
        ]
        for (catalog, text, expected) in catalogs {
            for models in [catalog, Array(catalog.reversed())] {
                let result = resolveModelReference(
                    ModelReferenceRequest(text: text), models, usable: { _ in false }
                )
                #expect(result.status == .resolved)
                #expect(result.model?.id == expected)
                #expect(result.thinkingLevel == nil)
                #expect(result.warning == nil)
            }
        }
    }

    @Test func exactLookupDoesNotParseSuffixOrUseNames() {
        let catalog = referenceCatalog + [
            referenceModel("openai", "literal:high"),
            referenceModel("openai", "opaque-id", name: "Friendly Model"),
        ]
        for models in [catalog, Array(catalog.reversed())] {
            for (text, expected) in [
                ("GPT-4O", "openai/gpt-4o"),
                ("OPENAI/gpt-4o", "openai/gpt-4o"),
                ("literal:high", "openai/literal:high"),
                ("openrouter/qwen/qwen3-coder:exacto", "openrouter/qwen/qwen3-coder:exacto"),
            ] {
                #expect(findExactModelReferenceMatch(text, models).map(modelReference) == expected)
            }
            for text in ["sonnet", "Friendly Model", "gpt-4o:high", "shared"] {
                #expect(findExactModelReferenceMatch(text, models) == nil)
            }
            for mode in [ModelThinkingSuffix.strict, .lenient, .none] {
                let result = resolveModelReference(
                    ModelReferenceRequest(text: "literal:high", thinkingSuffix: mode),
                    models, usable: { _ in false }
                )
                #expect(result.model?.id == "literal:high")
                #expect(result.thinkingLevel == nil)
                #expect(result.warning == nil)
            }
        }
    }

    @Test func invalidSuffixWarningsRemainExactThroughRecursionAndAmbiguity() {
        for models in [referenceCatalog, Array(referenceCatalog.reversed())] {
            for (text, expectedWarning) in [
                ("gpt-4o:random:high", "Invalid thinking level \"random\" in pattern \"gpt-4o:random\". Using default instead."),
                ("gpt-4o:random:other", "Invalid thinking level \"other\" in pattern \"gpt-4o:random:other\". Using default instead."),
                ("shared:random", "Invalid thinking level \"random\" in pattern \"shared:random\". Using default instead."),
            ] {
                let result = resolveModelReference(
                    ModelReferenceRequest(text: text, thinkingSuffix: .lenient),
                    models, usable: { _ in true }
                )
                #expect(result.warning == expectedWarning)
                #expect(result.thinkingLevel == nil)
                if text.hasPrefix("shared") {
                    #expect(result.status == .ambiguous)
                    #expect(result.candidates.map(modelReference).sorted() == ["gw-a/shared", "gw-b/shared"])
                    #expect(result.usableCount == 2)
                } else {
                    #expect(result.status == .resolved)
                    #expect(result.model?.id == "gpt-4o")
                }
            }
        }
    }
}
