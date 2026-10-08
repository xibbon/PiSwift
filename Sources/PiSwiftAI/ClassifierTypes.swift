import Foundation

/// Ordered choice criteria. Literal order is the order sent to System One.
public struct ClassifierChoiceCriteria: Sendable, ExpressibleByDictionaryLiteral {
    public let entries: [(String, String)]

    public init(_ entries: [(String, String)]) { self.entries = entries }
    public init(dictionaryLiteral elements: (String, String)...) { self.entries = elements }
}

public enum ClassifierQuestion: Sendable {
    case choice(instructions: String, criteria: ClassifierChoiceCriteria)
    case score(instructions: String, criteria: [String])
    case bool(instructions: String, trueCriterion: String, falseCriterion: String)
}

public struct ClassifierChoiceQuestion: Sendable {
    public let instructions: String
    public let criteria: ClassifierChoiceCriteria
    public init(instructions: String, criteria: ClassifierChoiceCriteria) {
        self.instructions = instructions; self.criteria = criteria
    }
}

public struct ClassifierScoreQuestion: Sendable {
    public let instructions: String
    public let criteria: [String]
    public init(instructions: String, criteria: [String]) {
        self.instructions = instructions; self.criteria = criteria
    }
}

public struct ClassifierBoolQuestion: Sendable {
    public let instructions: String
    public let trueCriterion: String
    public let falseCriterion: String
    public init(instructions: String, trueCriterion: String, falseCriterion: String) {
        self.instructions = instructions; self.trueCriterion = trueCriterion; self.falseCriterion = falseCriterion
    }
}

/// Ordered questions. Literal order is the order sent to System One.
public struct ClassifierQuestions: Sendable, ExpressibleByDictionaryLiteral {
    public let entries: [(String, ClassifierQuestion)]

    public init(_ entries: [(String, ClassifierQuestion)]) { self.entries = entries }
    public init(dictionaryLiteral elements: (String, ClassifierQuestion)...) { self.entries = elements }
}

public struct ClassifierContext: Sendable {
    public var state: [String: AnyCodable]
    public var questions: ClassifierQuestions
    /// Images judged together with `state`. Only models whose `input` includes `"image"` accept them;
    /// other models return an error result.
    public var images: [ImageContent]?

    public init(state: [String: AnyCodable], questions: ClassifierQuestions, images: [ImageContent]? = nil) {
        self.state = state
        self.questions = questions
        self.images = images
    }
}

public enum ClassifierAnswer: Sendable {
    case choice(choice: String, probabilities: [String: Double], confidence: Double)
    case score(score: Double, confidence: Double)
    case bool(probability: Double)
}

public struct ClassifierChoiceAnswer: Sendable {
    public let choice: String
    public let probabilities: [String: Double]
    public let confidence: Double
    public init(choice: String, probabilities: [String: Double], confidence: Double) {
        self.choice = choice; self.probabilities = probabilities; self.confidence = confidence
    }
}

public struct ClassifierScoreAnswer: Sendable {
    public let score: Double
    public let confidence: Double
    public init(score: Double, confidence: Double) {
        self.score = score; self.confidence = confidence
    }
}

public struct ClassifierBoolAnswer: Sendable {
    public let probability: Double
    public init(probability: Double) { self.probability = probability }
}

public enum ClassifierStopReason: String, Sendable {
    case stop
    case error
    case aborted
}

public struct ClassifierResult: Sendable {
    public var api: ClassifierApi
    public var provider: Provider
    public var model: String
    public var answers: [String: ClassifierAnswer]
    public var usage: Usage?
    public var stopReason: ClassifierStopReason
    public var errorMessage: String?
    public var timestamp: Int64

    public init(api: ClassifierApi, provider: Provider, model: String,
                answers: [String: ClassifierAnswer] = [:], usage: Usage? = nil,
                stopReason: ClassifierStopReason = .stop, errorMessage: String? = nil,
                timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        self.api = api
        self.provider = provider
        self.model = model
        self.answers = answers
        self.usage = usage
        self.stopReason = stopReason
        self.errorMessage = errorMessage
        self.timestamp = timestamp
    }
}

public typealias ClassifierPayloadHandler = @Sendable (OrderedJSON, ClassifierModel) async throws -> OrderedJSON?
public typealias ClassifierResponseHandler = @Sendable (ResponseSnapshot, ClassifierModel) async throws -> Void

public struct ClassifierOptions: Sendable {
    public var signal: CancellationToken?
    public var apiKey: String?
    public var httpClient: (any ProviderHTTPClient)?
    public var env: [String: String]?
    public var onPayload: ClassifierPayloadHandler?
    public var onResponse: ClassifierResponseHandler?
    public var headers: ProviderHeaders?
    public var timeoutMs: Int?
    public var maxRetries: Int?
    public var maxRetryDelayMs: Int?
    public var temperature: Double?

    public init(signal: CancellationToken? = nil, apiKey: String? = nil,
                httpClient: (any ProviderHTTPClient)? = nil, env: [String: String]? = nil,
                onPayload: ClassifierPayloadHandler? = nil,
                onResponse: ClassifierResponseHandler? = nil,
                headers: ProviderHeaders? = nil, timeoutMs: Int? = nil,
                maxRetries: Int? = nil, maxRetryDelayMs: Int? = nil,
                temperature: Double? = nil) {
        self.signal = signal
        self.apiKey = apiKey
        self.httpClient = httpClient
        self.env = env
        self.onPayload = onPayload
        self.onResponse = onResponse
        self.headers = headers
        self.timeoutMs = timeoutMs
        self.maxRetries = maxRetries
        self.maxRetryDelayMs = maxRetryDelayMs
        self.temperature = temperature
    }
}

/// Rejects classifier images for models whose catalog entry does not accept image input.
public func assertClassifierInputSupported(model: ClassifierModel, context: ClassifierContext) throws {
    if let images = context.images, !images.isEmpty, !model.input.contains(.image) {
        throw ClassifierError(message: "Model \(model.provider)/\(model.id) does not accept image input")
    }
}
