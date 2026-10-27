#if os(macOS) || os(Linux)
import Foundation
import Testing

private func checkSystemOneCatalogGenerator(_ checks: String) throws {
    let generator = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Scripts/generate-ai-catalogs.js")
    let script = #"""
    const assert = require("node:assert/strict");
    const { swiftClassifierModel } = require(process.argv[1]);
    const model = {
      type: "classifier", id: "test", name: "Test", api: "typesafe-system-one",
      provider: "test", baseUrl: "https://example.test/v1", input: ["text", "image"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 4096,
    };
    """# + checks
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["node", "-e", script, generator.path]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0, Comment(rawValue: String(decoding: data, as: UTF8.self)))
}

@Suite("System One catalog generator")
struct SystemOneCatalogGeneratorTests {
    @Test func emitsClassifierCompat() throws {
        try checkSystemOneCatalogGenerator(#"""
        for (const [imageInput, swiftCase] of [
          ["assets", "assets"], ["images", "images"], ["state-image-urls", "stateImageURLs"],
        ]) {
          for (const sendImageOptInHeader of [true, false]) {
            const output = swiftClassifierModel({ ...model, compat: { imageInput, sendImageOptInHeader } });
            assert.ok(output.includes(`compat: SystemOneCompat(imageInput: .${swiftCase}, sendImageOptInHeader: ${sendImageOptInHeader})`), output);
          }
        }
        """#)
    }

    @Test func keepsOptionalClassifierCompatFields() throws {
        try checkSystemOneCatalogGenerator(#"""
        assert.ok(!swiftClassifierModel(model).includes("compat:"));
        assert.ok(swiftClassifierModel({ ...model, compat: {} }).includes("compat: SystemOneCompat()"));
        assert.ok(swiftClassifierModel({ ...model, compat: { imageInput: "assets" } }).includes("compat: SystemOneCompat(imageInput: .assets)"));
        assert.ok(swiftClassifierModel({ ...model, compat: { sendImageOptInHeader: false } }).includes("compat: SystemOneCompat(sendImageOptInHeader: false)"));
        """#)
    }

    @Test func rejectsUnknownClassifierCompatKeysAndValues() throws {
        try checkSystemOneCatalogGenerator(#"""
        for (const compat of [null, false, 1, "assets", []]) {
          assert.throws(() => swiftClassifierModel({ ...model, compat }), /Expected classifier compat object/);
        }
        for (const compat of [{ unknown: true }, { supportsStore: true }, { imageInput: "assets", extra: false }]) {
          assert.throws(() => swiftClassifierModel({ ...model, compat }), /Unmapped classifier compat field/);
        }
        for (const imageInput of [null, false, 1, [], {}, "webp", "toString", "__proto__"]) {
          assert.throws(() => swiftClassifierModel({ ...model, compat: { imageInput } }), /Unknown classifier imageInput/);
        }
        for (const sendImageOptInHeader of [null, 0, 1, "true", "false", [], {}]) {
          assert.throws(() => swiftClassifierModel({ ...model, compat: { sendImageOptInHeader } }), /Expected classifier sendImageOptInHeader boolean/);
        }
        """#)
    }
}
#endif
