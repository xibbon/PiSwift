import Foundation
import Testing
@testable import PiSwiftAI

private actor A3ImageClient: ProviderHTTPClient {
    private var requests: [URLRequest] = []
    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        requests.append(request)
        let output = #"{"answers":{}}"#
        let body = request.url?.path.hasSuffix("/run") == true
            ? #"{"success":true,"result":\#(output)}"# : output
        return ProviderHTTPResponse(statusCode: 200, body: Data(body.utf8))
    }
    func captured() -> [URLRequest] { requests }
}

private func a3ImageModel(id: String = "jev-latest", api: ClassifierApi = .typesafeSystemOne,
                          provider: String = "typesafe", baseUrl: String = "https://api.typesafe.ai/v1",
                          input: [ModelInput] = [.text, .image], compat: SystemOneCompat? = nil) -> ClassifierModel {
    ClassifierModel(id: id, name: id, api: api, provider: provider, baseUrl: baseUrl,
        input: input, cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 32_000, compat: compat)
}

private func a3ImageContext(_ images: [ImageContent]? = [ImageContent(data: "cG5n", mimeType: "image/png")]) -> ClassifierContext {
    ClassifierContext(state: ["text": AnyCodable("Describe")], questions: [:], images: images)
}

private func a3Body(_ request: URLRequest) throws -> [String: Any] {
    let data = try #require(request.httpBody)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Test func a3SystemOneRejectsTextOnlyBeforeSending() async {
    let client = A3ImageClient()
    let options = ClassifierOptions(apiKey: "secret", httpClient: client)
    let typesafe = await classifyTypeSafeSystemOne(model: a3ImageModel(input: [.text]),
        context: a3ImageContext(), options: options)
    #expect(typesafe.errorMessage == "System One API does not support image input for jev-latest")
    let cloudflare = await classifyCloudflareWorkersAISystemOne(
        model: a3ImageModel(api: .cloudflareWorkersAISystemOne, input: [.text]),
        context: a3ImageContext(), options: options)
    #expect(cloudflare.errorMessage == "Cloudflare Workers AI does not support image input for jev-latest")
    #expect(typesafe.stopReason == .error)
    #expect(cloudflare.stopReason == .error)
    #expect(await client.captured().isEmpty)
}

@Test func a3TypeSafeAssetsAndLaterTextRequest() async throws {
    let client = A3ImageClient()
    let options = ClassifierOptions(apiKey: "secret", httpClient: client)
    let model = a3ImageModel()
    let result = await classifyTypeSafeSystemOne(model: model, context: a3ImageContext([
        ImageContent(data: "cG5n", mimeType: "image/png"), ImageContent(data: "anBlZw==", mimeType: "image/jpeg")
    ]), options: options)
    #expect(result.stopReason == .stop)
    let text = await classifyTypeSafeSystemOne(model: model, context: a3ImageContext(nil), options: options)
    let empty = await classifyTypeSafeSystemOne(model: model, context: a3ImageContext([]), options: options)
    #expect(text.stopReason == .stop)
    #expect(empty.stopReason == .stop)
    let requests = await client.captured()
    #expect(requests.count == 3)
    let body = try a3Body(requests[0])
    let state = try #require(body["state"] as? [Any])
    #expect(state.count == 3)
    #expect(state[0] as? String == "<image-1>")
    #expect(state[1] as? String == "<image-2>")
    #expect(state[2] as? [String: String] == ["text": "Describe"])
    let assets = try #require(body["assets"] as? [String: [String: String]])
    #expect(assets == ["<image-1>": ["type": "image", "format": "png", "data_base64": "cG5n"],
                       "<image-2>": ["type": "image", "format": "jpeg", "data_base64": "anBlZw=="]])
    #expect(body["images"] == nil)
    #expect(requests[0].value(forHTTPHeaderField: "TypeSafe-Danger-Zone-Images") == "true")
    for request in requests.dropFirst() {
        #expect(request.value(forHTTPHeaderField: "TypeSafe-Danger-Zone-Images") == nil)
        #expect(String(data: try #require(request.httpBody), encoding: .utf8)
            == #"{"model":"jev-latest","state":{"text":"Describe"},"questions":{}}"#)
    }
}

@Test(arguments: ["image/webp", "image/gif", "image/jpg"])
func a3TypeSafeRejectsAssetFormats(mime: String) async {
    let client = A3ImageClient()
    let result = await classifyTypeSafeSystemOne(model: a3ImageModel(),
        context: a3ImageContext([ImageContent(data: "data", mimeType: mime)]),
        options: ClassifierOptions(apiKey: "secret", httpClient: client))
    #expect(result.stopReason == .error)
    #expect(result.errorMessage == "System One API accepts PNG and JPEG images for jev-latest, got \(mime)")
    #expect(await client.captured().isEmpty)
}

private struct A3RouterRow: Sendable {
    let provider: String
    let baseUrl: String
    let compat: SystemOneCompat?
}

@Test(arguments: [
    A3RouterRow(provider: "openrouter", baseUrl: "https://openrouter.ai/api/v1", compat: nil),
    A3RouterRow(provider: "openrouter", baseUrl: "https://proxy.example.com/v1", compat: nil),
    A3RouterRow(provider: "custom", baseUrl: "https://us.openrouter.ai/api/v1", compat: nil),
    A3RouterRow(provider: "custom", baseUrl: "https://proxy.example.com/v1",
                compat: SystemOneCompat(imageInput: .stateImageURLs, sendImageOptInHeader: false))
])
private func a3OpenRouterImageForms(row: A3RouterRow) async throws {
    let client = A3ImageClient()
    let result = await classifyTypeSafeSystemOne(model: a3ImageModel(id: "typesafe/jev-1.14",
        provider: row.provider, baseUrl: row.baseUrl, compat: row.compat), context: a3ImageContext(),
        options: ClassifierOptions(apiKey: "secret", httpClient: client))
    #expect(result.stopReason == .stop)
    let request = try #require(await client.captured().first)
    #expect(request.url?.absoluteString == row.baseUrl + "/systemone")
    let body = try a3Body(request)
    #expect(body.count == 3)
    let state = try #require(body["state"] as? [Any])
    #expect(state.count == 2)
    let part = try #require(state[0] as? [String: Any])
    #expect(part["type"] as? String == "image_url")
    #expect(part["image_url"] as? [String: String] == ["url": "data:image/png;base64,cG5n"])
    #expect(state[1] as? [String: String] == ["text": "Describe"])
    #expect(body["assets"] == nil)
    #expect(body["images"] == nil)
    #expect(request.value(forHTTPHeaderField: "TypeSafe-Danger-Zone-Images") == nil)
}

@Test func a3CompatFieldsOverrideDefaultsIndependently() async throws {
    let rows: [(ClassifierModel, String, String?)] = [
        (a3ImageModel(compat: SystemOneCompat(sendImageOptInHeader: false)), "assets", nil),
        (a3ImageModel(compat: SystemOneCompat(imageInput: .stateImageURLs)), "state", "true"),
        (a3ImageModel(provider: "openrouter", compat: SystemOneCompat(imageInput: .assets)), "assets", nil),
        (a3ImageModel(id: "@cf/cloudflare/clef", api: .cloudflareWorkersAISystemOne,
            compat: SystemOneCompat(imageInput: .assets)), "assets", nil),
        (a3ImageModel(id: "@cf/cloudflare/clef", api: .cloudflareWorkersAISystemOne,
            compat: SystemOneCompat(sendImageOptInHeader: true)), "images", "true")
    ]
    for (model, field, header) in rows {
        let client = A3ImageClient()
        let result = await classify(model: model, context: a3ImageContext(),
            options: ClassifierOptions(apiKey: "secret", httpClient: client))
        #expect(result.stopReason == .stop)
        let request = try #require(await client.captured().first)
        let root = try a3Body(request)
        let body = model.api == .cloudflareWorkersAISystemOne
            ? try #require(root["input"] as? [String: Any]) : root
        #expect(body[field] != nil)
        if field == "state" { #expect(body[field] is [Any]) }
        #expect(request.value(forHTTPHeaderField: "TypeSafe-Danger-Zone-Images") == header)
    }
}

@Test func a3ImageOptInHeaderCanBeOverriddenOrDeleted() async throws {
    let client = A3ImageClient()
    for header: ProviderHeaders in [["typesafe-danger-zone-images": "custom"], ["typesafe-danger-zone-images": nil]] {
        let result = await classifyTypeSafeSystemOne(model: a3ImageModel(), context: a3ImageContext(),
            options: ClassifierOptions(apiKey: "secret", httpClient: client, headers: header))
        #expect(result.stopReason == .stop)
    }
    let requests = await client.captured()
    #expect(requests[0].value(forHTTPHeaderField: "TypeSafe-Danger-Zone-Images") == "custom")
    #expect(requests[1].value(forHTTPHeaderField: "TypeSafe-Danger-Zone-Images") == nil)
}

@Test(arguments: ["@cf/cloudflare/clef", "@cf/cloudflare/clef-flash", "@cf/cloudflare/clef-omni", "@cf/acme/clef-finetune"])
func a3CloudflareDataURLs(id: String) async throws {
    let client = A3ImageClient()
    let model = a3ImageModel(id: id, api: .cloudflareWorkersAISystemOne,
        provider: "cloudflare-workers-ai", baseUrl: "https://api.cloudflare.com/client/v4/accounts/{CLOUDFLARE_ACCOUNT_ID}/ai",
        compat: id == "@cf/acme/clef-finetune" ? SystemOneCompat(imageInput: .images) : nil)
    let result = await classifyCloudflareWorkersAISystemOne(model: model, context: a3ImageContext([
        ImageContent(data: "cG5n", mimeType: "image/png"), ImageContent(data: "anBlZw==", mimeType: "image/jpeg"),
        ImageContent(data: "d2VicA==", mimeType: "image/webp"), ImageContent(data: "four", mimeType: "image/png")
    ]), options: ClassifierOptions(apiKey: "secret", httpClient: client, env: ["CLOUDFLARE_ACCOUNT_ID": "account"]))
    #expect(result.stopReason == .stop)
    let request = try #require(await client.captured().first)
    #expect(request.url?.absoluteString == "https://api.cloudflare.com/client/v4/accounts/account/ai/run")
    let body = try #require(a3Body(request)["input"] as? [String: Any])
    #expect(body.count == 3)
    #expect(body["state"] as? [String: String] == ["text": "Describe"])
    #expect(body["images"] as? [String] == ["data:image/png;base64,cG5n", "data:image/jpeg;base64,anBlZw==",
                                           "data:image/webp;base64,d2VicA==", "data:image/png;base64,four"])
    #expect(body["assets"] == nil)
    #expect(request.value(forHTTPHeaderField: "TypeSafe-Danger-Zone-Images") == nil)
}

@Test func a3CloudflareRejectsCountAndFormatBeforeSending() async {
    let client = A3ImageClient()
    let options = ClassifierOptions(apiKey: "secret", httpClient: client)
    let model = a3ImageModel(id: "@cf/cloudflare/clef-flash", api: .cloudflareWorkersAISystemOne)
    let image = ImageContent(data: "data", mimeType: "image/gif")
    let count = await classifyCloudflareWorkersAISystemOne(model: model,
        context: a3ImageContext(Array(repeating: image, count: 5)), options: options)
    #expect(count.stopReason == .error)
    #expect(count.errorMessage == "Cloudflare Workers AI accepts at most 4 images for @cf/cloudflare/clef-flash, got 5")
    let format = await classifyCloudflareWorkersAISystemOne(model: model,
        context: a3ImageContext([image]), options: options)
    #expect(format.stopReason == .error)
    #expect(format.errorMessage == "Cloudflare Workers AI accepts PNG, JPEG, and WebP images for @cf/cloudflare/clef-flash, got image/gif")
    #expect(await client.captured().isEmpty)
}

@Test(arguments: ["typesafe/jev", "typesafe/jev-1.14.0"])
func a3CloudflareJevAssets(id: String) async throws {
    let client = A3ImageClient()
    let result = await classifyCloudflareWorkersAISystemOne(
        model: a3ImageModel(id: id, api: .cloudflareWorkersAISystemOne), context: a3ImageContext(),
        options: ClassifierOptions(apiKey: "secret", httpClient: client))
    #expect(result.stopReason == .stop)
    let request = try #require(await client.captured().first)
    let body = try #require(a3Body(request)["input"] as? [String: Any])
    let state = try #require(body["state"] as? [Any])
    #expect(state[0] as? String == "<image-1>")
    #expect(state[1] as? [String: String] == ["text": "Describe"])
    #expect(body["assets"] as? [String: [String: String]]
        == ["<image-1>": ["type": "image", "format": "png", "data_base64": "cG5n"]])
    #expect(body["images"] == nil)
    #expect(request.value(forHTTPHeaderField: "TypeSafe-Danger-Zone-Images") == nil)
}

@Test func a3StateImageURLsLeaveFormatAndCountToService() async throws {
    let client = A3ImageClient()
    let result = await classifyTypeSafeSystemOne(model: a3ImageModel(provider: "openrouter"),
        context: a3ImageContext(Array(repeating: ImageContent(data: "data", mimeType: "image/gif"), count: 5)),
        options: ClassifierOptions(apiKey: "secret", httpClient: client))
    #expect(result.stopReason == .stop)
    let request = try #require(await client.captured().first)
    #expect((try a3Body(request)["state"] as? [Any])?.count == 6)
}

@Test(arguments: [SystemOneImageInput.assets, .images, .stateImageURLs])
func a3ClassifierCompatCodableAndValueCopies(form: SystemOneImageInput) throws {
    let compat = SystemOneCompat(imageInput: form, sendImageOptInHeader: false)
    let model = a3ImageModel(api: .cloudflareWorkersAISystemOne, provider: "cloudflare-workers-ai",
        baseUrl: "https://api.cloudflare.com/client/v4/accounts/{CLOUDFLARE_ACCOUNT_ID}/ai", compat: compat)
    let encoded = try JSONEncoder().encode(model)
    #expect(try JSONDecoder().decode(ClassifierModel.self, from: encoded).compat == compat)
    let any = try JSONDecoder().decode(AnyModel.self, from: JSONEncoder().encode(AnyModel.classifier(model)))
    if case .classifier(let decoded) = any { #expect(decoded.compat == compat) }
    else { Issue.record("Classifier type was lost") }
    let raw = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let wireCompat = try #require(raw["compat"] as? [String: Any])
    #expect(wireCompat["imageInput"] as? String == form.rawValue)
    #expect(wireCompat["sendImageOptInHeader"] as? Bool == false)
    #expect(model.with(baseUrl: "https://proxy.example.com").compat == compat)
    let resolved = resolveCloudflareModel(model, env: ["CLOUDFLARE_ACCOUNT_ID": "account"])
    #expect(resolved.baseUrl == "https://api.cloudflare.com/client/v4/accounts/account/ai")
    #expect(resolved.compat == compat)
}

@Test func a3ParsedOpenRouterClassifierKeepsCompat() throws {
    let data = Data(#"{"type":"classifier","id":"typesafe/jev-1.14","name":"Jev","api":"typesafe-system-one","provider":"openrouter","baseUrl":"https://proxy.example.com/v1","input":["text","image"],"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0},"contextWindow":32000,"compat":{"imageInput":"state-image-urls","sendImageOptInHeader":false}}"#.utf8)
    let expected = SystemOneCompat(imageInput: .stateImageURLs, sendImageOptInHeader: false)
    #expect(try JSONDecoder().decode(ClassifierModel.self, from: data).compat == expected)
    let model = try JSONDecoder().decode(AnyModel.self, from: data)
    if case .classifier(let classifier) = model { #expect(classifier.compat == expected) }
    else { Issue.record("Classifier type was lost") }
}

@Test func a3CompatDoesNotChangeTextBodiesOrAddOptInHeader() async throws {
    for api: ClassifierApi in [.typesafeSystemOne, .cloudflareWorkersAISystemOne] {
        for form: SystemOneImageInput in [.assets, .images, .stateImageURLs] {
            let client = A3ImageClient()
            let model = a3ImageModel(api: api, provider: "openrouter",
                compat: SystemOneCompat(imageInput: form, sendImageOptInHeader: true))
            for images: [ImageContent]? in [nil, []] {
                let result = await classify(model: model, context: a3ImageContext(images),
                    options: ClassifierOptions(apiKey: "secret", httpClient: client))
                #expect(result.stopReason == .stop)
            }
            for request in await client.captured() {
                let expected = api == .typesafeSystemOne
                    ? #"{"model":"jev-latest","state":{"text":"Describe"},"questions":{}}"#
                    : #"{"model":"jev-latest","input":{"state":{"text":"Describe"},"questions":{}}}"#
                #expect(String(data: try #require(request.httpBody), encoding: .utf8) == expected)
                #expect(request.value(forHTTPHeaderField: "TypeSafe-Danger-Zone-Images") == nil)
            }
        }
    }
}

@Test func a3ClassifierCompatLegacyAndInvalidDecoding() throws {
    let model = a3ImageModel()
    let data = try JSONEncoder().encode(model)
    #expect(try JSONDecoder().decode(ClassifierModel.self, from: data).compat == nil)
    let headerOnly = SystemOneCompat(sendImageOptInHeader: false)
    #expect(try JSONDecoder().decode(SystemOneCompat.self, from: JSONEncoder().encode(headerOnly)) == headerOnly)
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(SystemOneCompat.self, from: Data(#"{"imageInput":"unknown"}"#.utf8))
    }
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(SystemOneCompat.self, from: Data(#"{"sendImageOptInHeader":"false"}"#.utf8))
    }
}
