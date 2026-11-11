import Foundation

/// Account charge returned with OpenRouter chat usage. Component costs remain catalog estimates.
public struct OpenRouterUsageAccounting: Sendable, Decodable {
    public struct CostDetails: Sendable, Decodable {
        public var upstreamInferenceCost: Double?
        public var upstreamInferencePromptCost: Double?
        public var upstreamInferenceCompletionsCost: Double?

        enum CodingKeys: String, CodingKey {
            case upstreamInferenceCost = "upstream_inference_cost"
            case upstreamInferencePromptCost = "upstream_inference_prompt_cost"
            case upstreamInferenceCompletionsCost = "upstream_inference_completions_cost"
        }

        public init(upstreamInferenceCost: Double? = nil, upstreamInferencePromptCost: Double? = nil,
                    upstreamInferenceCompletionsCost: Double? = nil) {
            self.upstreamInferenceCost = upstreamInferenceCost
            self.upstreamInferencePromptCost = upstreamInferencePromptCost
            self.upstreamInferenceCompletionsCost = upstreamInferenceCompletionsCost
        }
    }

    public var cost: Double?
    public var isBYOK: Bool?
    public var costDetails: CostDetails?

    enum CodingKeys: String, CodingKey {
        case cost
        case isBYOK = "is_byok"
        case costDetails = "cost_details"
    }

    public init(cost: Double?, isBYOK: Bool?, costDetails: CostDetails?) {
        self.cost = cost
        self.isBYOK = isBYOK
        self.costDetails = costDetails
    }
}

public func isOpenRouterModel(provider: String, baseUrl: String) -> Bool {
    provider == "openrouter" || baseUrl.contains("openrouter.ai")
}

/// Use the reported total only when all required amounts are finite and non-negative.
public func applyOpenRouterReportedCost(_ reported: OpenRouterUsageAccounting, usage: inout Usage) {
    guard let charge = reported.cost, charge.isFinite, charge >= 0 else { return }
    if reported.isBYOK == false {
        usage.cost.total = charge
        usage.cost.totalFromProvider = true
    } else if reported.isBYOK == true, let details = reported.costDetails {
        let upstream: Double
        if let value = details.upstreamInferenceCost {
            upstream = value
        } else if let prompt = details.upstreamInferencePromptCost,
                  let completion = details.upstreamInferenceCompletionsCost,
                  prompt.isFinite, prompt >= 0, completion.isFinite, completion >= 0 {
            upstream = prompt + completion
        } else {
            return
        }
        guard upstream.isFinite, upstream >= 0, (charge + upstream).isFinite else { return }
        usage.cost.total = charge + upstream
        usage.cost.totalFromProvider = true
    }
}
