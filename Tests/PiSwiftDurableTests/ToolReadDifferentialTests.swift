import Foundation
import Testing
import PiSwiftChord
@testable import PiSwiftDurable

@Suite struct ToolReadDifferentialTests {
    private let context = ChordContext.background
    private func unpack(_ value: JSONValue) throws -> JSONValue {
        if let parts = value["$text"]?.arrayValue {
            var text = ""
            for part in parts {
                if let literal = part.stringValue { text += literal }
                else {
                    let run = try #require(part.arrayValue)
                    text += String(repeating: try #require(run[1].stringValue), count: Int(try #require(run[0].numberValue)))
                }
            }
            return .string(text)
        }
        if case .array(let values) = value { return .array(try values.map(unpack)) }
        if case .object(let object) = value {
            var decoded = JSONObject()
            for (key, child) in object { decoded[key] = try unpack(child) }
            return .object(decoded)
        }
        return value
    }
    private func number(_ value: JSONValue?) -> Double? {
        if value?.stringValue == "NaN" { return .nan }
        return value?.numberValue
    }
    private func outcome(_ body: () async throws -> ToolExecutionResult) async throws -> JSONValue {
        do {
            let result = try await body()
            var object: JSONObject = ["content": .array((result.content ?? []).map { block in
                if case .text(let text) = block { return .object(["type": "text", "text": .string(text.text)]) }
                return .null
            })]
            if let isError = result.isError { object["isError"] = .bool(isError) }
            if let details = result.details { object["details"] = details }
            if let diagnostics = result.diagnostics { object["diagnostics"] = try JSONValue(encoding: diagnostics) }
            return .object(object)
        } catch { return ["error": .string(String(describing: error))] }
    }
    @Test("returns the whole-file reference result for all 400 seeds and four trials")
    func wholeFileReference() async throws {
        let url = try #require(Bundle.module.url(forResource: "read-differential", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try unpack(JSONValue(jsonData: Data(contentsOf: url)))
        #expect(fixture["tag"] == "v1.1.0")
        #expect(fixture["differences"] == 0)
        let files = try #require(fixture["files"]?.arrayValue)
        #expect(files.count == 400)
        let directory = try toolTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let env = LocalExecutionEnv(cwd: directory.path)
        let api = try toolTestApi(env: env)
        var trialsRun = 0
        for file in files {
            let seed = try #require(file["seed"]?.numberValue)
            let base64 = try #require(file["base64"]?.stringValue)
            let bytes = try #require(Data(base64Encoded: base64))
            try bytes.write(to: directory.appendingPathComponent("f.txt"))
            let trials = try #require(file["trials"]?.arrayValue)
            #expect(trials.count == 4)
            for trial in trials {
                let offset = number(trial["offset"]), limit = number(trial["limit"])
                let actual = try await outcome {
                    try await executeReadTool(.init(path: "f.txt", offset: offset, limit: limit), api, context)
                }
                #expect(actual == trial["actual"], "seed \(seed), offset \(String(describing: offset)), limit \(String(describing: limit))")
                #expect(actual == trial["expected"], "whole-file reference for seed \(seed)")
                trialsRun += 1
            }
        }
        #expect(trialsRun == 1600)
    }
    @Test("detects an APNG with acTL beyond the header")
    func animatedPngBeyondHeader() async throws {
        func chunk(_ type: String, _ count: Int) -> [UInt8] {
            [UInt8((count >> 24) & 255), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255), UInt8(count & 255)]
            + Array(type.utf8) + [UInt8](repeating: 0, count: count + 4)
        }
        let png: [UInt8] = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
            + chunk("IHDR", 13) + chunk("iCCP", 200_000) + chunk("acTL", 8) + chunk("IDAT", 10)
        let directory = try toolTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(png).write(to: directory.appendingPathComponent("a.png"))
        let env = LocalExecutionEnv(cwd: directory.path)
        let result = try await createReadTool().execute(["path": "a.png"], toolTestApi(env: env), context)
        #expect(detectSupportedImageMimeType(png) == nil)
        #expect(result.isError == nil)
        // Whole-file decoding removes no BOM and uses replacement characters for invalid UTF-8.
        var decoder = StreamDecoder()
        let referenceText = decoder.decode(png) + decoder.decode()
        let reference = truncateHead(referenceText)
        #expect(toolResultText(result) == reference.content)
        #expect(result.details?["truncation"]?["totalBytes"] == .number(Double(reference.totalBytes)))
        #expect(result.details?["truncation"]?["totalLines"] == .number(Double(reference.totalLines)))
    }
}
