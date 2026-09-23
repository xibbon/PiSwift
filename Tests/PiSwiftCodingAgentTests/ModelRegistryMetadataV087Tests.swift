import Foundation
import Testing
import PiSwiftCodingAgent

@Test func modelRegistryParsesCustomAndOverrideInputLimitsAndPromptCache() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-model-metadata-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let json = """
    {
      "providers": {
        "local": {
          "api": "openai-completions",
          "baseUrl": "http://localhost:1234/v1",
          "models": [{
            "id": "local-vision",
            "input": ["text", "image"],
            "inputLimits": {"maxRequestBytes": 12345, "images": {
              "maxPerMessage": 2, "resize": {"maxWidth": 1024, "jpegQuality": 72}
            }},
            "promptCache": {"short": 120}
          }]
        },
        "openai": {
          "modelOverrides": {
            "gpt-4-turbo": {
              "name": "Configured GPT-4 Turbo",
              "inputLimits": {"images": {"maxPerRequest": 3}},
              "promptCache": {"long": 2400}
            }
          }
        }
      }
    }
    """
    try json.write(to: directory.appendingPathComponent("models.json"), atomically: true, encoding: .utf8)

    let registry = ModelRegistry(AuthStorage(":memory:"), directory.path)
    let custom = try #require(registry.find("local", "local-vision"))
    #expect(custom.inputLimits?.maxRequestBytes == 12_345)
    #expect(custom.inputLimits?.images?.maxPerMessage == 2)
    #expect(custom.inputLimits?.images?.resize?.maxWidth == 1_024)
    #expect(custom.inputLimits?.images?.resize?.jpegQuality == 72)
    #expect(custom.promptCache?.short == 120)
    #expect(custom.promptCache?.long == nil)

    let overridden = try #require(registry.find("openai", "gpt-4-turbo"))
    #expect(overridden.name == "Configured GPT-4 Turbo")
    #expect(overridden.inputLimits?.images?.maxPerRequest == 3)
    #expect(overridden.promptCache?.long == 2_400)
    #expect(overridden.promptCache?.short == nil)
}
