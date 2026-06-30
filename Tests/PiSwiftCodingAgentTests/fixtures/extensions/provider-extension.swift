import PiExtensionSDK

@_cdecl("piExtensionMain")
public func piExtensionMain(_ raw: UnsafeMutableRawPointer) {
    withExtensionAPI(raw) { pi in
        pi.registerProvider(HookProviderConfig(
            provider: "fixture-extension-provider",
            api: .openAIResponses,
            baseUrl: "https://example.invalid/v1",
            apiKey: "fixture-token",
            models: [
                HookProviderModel(
                    id: "fixture-extension-model",
                    name: "Fixture Extension Model",
                    contextWindow: 8192,
                    maxTokens: 4096
                )
            ]
        ))
    }
}
