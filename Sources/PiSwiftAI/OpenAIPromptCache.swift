public let OPENAI_PROMPT_CACHE_KEY_MAX_LENGTH = 64

public func clampOpenAIPromptCacheKey(_ key: String?) -> String? {
    guard let key else { return nil }
    let chars = Array(key)
    if chars.count <= OPENAI_PROMPT_CACHE_KEY_MAX_LENGTH { return key }
    return String(chars.prefix(OPENAI_PROMPT_CACHE_KEY_MAX_LENGTH))
}
