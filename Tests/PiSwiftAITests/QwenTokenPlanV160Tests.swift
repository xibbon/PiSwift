import Foundation
import Testing
@testable import PiSwiftAI

private let qwenV160KeyCases: [(provider: String, plan: String, shared: String, name: String, gateway: String)] = [
    ("qwen-token-plan", "QWEN_TOKEN_PLAN_TEAM_API_KEY", "QWEN_TOKEN_PLAN_API_KEY", "Qwen Token Plan Team", "https://token-plan.maas.qwencloudapi.com/compatible-mode/v1"),
    ("qwen-token-plan-cn", "QWEN_TOKEN_PLAN_TEAM_CN_API_KEY", "QWEN_TOKEN_PLAN_CN_API_KEY", "Qwen Token Plan Team CN", "https://token-plan.maas.qianwenaiapi.com/compatible-mode/v1"),
    ("qwen-token-plan-individual", "QWEN_TOKEN_PLAN_INDIVIDUAL_API_KEY", "QWEN_TOKEN_PLAN_API_KEY", "Qwen Token Plan Individual", "https://token-plan.maas.qwencloudapi.com/compatible-mode/v1"),
    ("qwen-token-plan-individual-cn", "QWEN_TOKEN_PLAN_INDIVIDUAL_CN_API_KEY", "QWEN_TOKEN_PLAN_CN_API_KEY", "Qwen Token Plan Individual CN", "https://token-plan.maas.qianwenaiapi.com/compatible-mode/v1"),
]

// Upstream: qwen-token-plan-models.test.ts, "prefers the per-plan key on %s and falls back to the shared one".
@Test func qwenV160PrefersPerPlanKeyAndFallsBackToShared() throws {
    for row in qwenV160KeyCases {
        let both = [row.plan: "plan", row.shared: "shared"]
        #expect(findEnvKeys(provider: row.provider, env: both) == [row.plan, row.shared])
        #expect(getEnvApiKey(provider: row.provider, env: both) == "plan")
        #expect(findEnvKeys(provider: row.provider, env: [row.shared: "shared"]) == [row.shared])
        #expect(getEnvApiKey(provider: row.provider, env: [row.shared: "shared"]) == "shared")
        #expect(getEnvApiKey(provider: row.provider, env: [row.plan: " \n", row.shared: "shared"]) == "shared")
        #expect(getBuiltinProviderAuth(row.provider)?.apiKey?.envVars == [row.plan, row.shared])
    }
}

// Upstream: qwen-token-plan-models.test.ts, "keeps a per-plan key away from the other plan".
@Test func qwenV160KeepsPerPlanKeysSeparate() {
    #expect(findEnvKeys(provider: "qwen-token-plan", env: ["QWEN_TOKEN_PLAN_INDIVIDUAL_API_KEY": "test"]) == nil)
    #expect(getEnvApiKey(provider: "qwen-token-plan", env: ["QWEN_TOKEN_PLAN_INDIVIDUAL_API_KEY": "test"]) == nil)
    #expect(findEnvKeys(provider: "qwen-token-plan-individual-cn", env: ["QWEN_TOKEN_PLAN_TEAM_CN_API_KEY": "test"]) == nil)
    #expect(getEnvApiKey(provider: "qwen-token-plan-individual-cn", env: ["QWEN_TOKEN_PLAN_TEAM_CN_API_KEY": "test"]) == nil)
}

@Test func qwenV160NamesAndGatewaysMatchProviderWrappers() throws {
    for row in qwenV160KeyCases {
        #expect(getBuiltinProviderDisplayName(row.provider) == row.name)
        let provider = try #require(KnownProvider(rawValue: row.provider))
        let model = try #require(getModels(provider: provider).first { $0.id == "qwen3.8-max" })
        #expect(model.baseUrl == row.gateway)
    }
}

// Upstream: qwen-token-plan-models.test.ts, "omits retired models on %s".
@Test func qwenV160TeamOmitsRetiredModels() throws {
    for name in ["qwen-token-plan", "qwen-token-plan-cn"] {
        let provider = try #require(KnownProvider(rawValue: name))
        let ids = Set(getModels(provider: provider).map(\.id))
        for retired in ["qwen3.8-max-preview", "deepseek-v3.2", "deepseek-v4-flash"] {
            #expect(!ids.contains(retired))
        }
    }
}

// Upstream: qwen-token-plan-models.test.ts, "exposes exactly the documented Individual text models"
// and "exposes exactly the documented Individual text models on the China endpoint".
@Test func qwenV160IndividualTextModelsMatchDocumentedList() throws {
    let expected: Set<String> = [
        "deepseek-v4-flash-0731", "deepseek-v4-pro", "deepseek-v4-pro-0813",
        "deepseek-v4.1-flash", "deepseek-v4.1-flash-1017", "glm-5.2", "glm-5.3",
        "qwen3.6-flash", "qwen3.7-max", "qwen3.7-plus", "qwen3.8-flash",
        "qwen3.8-max", "qwen4-max-preview",
    ]
    for name in ["qwen-token-plan-individual", "qwen-token-plan-individual-cn"] {
        let provider = try #require(KnownProvider(rawValue: name))
        let models = getModels(provider: provider)
        #expect(models.count == expected.count)
        #expect(Set(models.map(\.id)) == expected)
    }
}
