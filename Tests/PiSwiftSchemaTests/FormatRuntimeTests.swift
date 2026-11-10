import Foundation
import Testing
@testable import PiSwiftSchema

@Test("all 21 format checks finish on long hostile inputs", .timeLimit(.minutes(1)))
func formatLongInputs() throws {
    var inputs = [
        String(repeating: "a", count: 100_000),
        String(repeating: "[", count: 100_000),
        String(repeating: "a", count: 99_999) + "\n",
        "http://xn--" + String(repeating: "a", count: 99_989),
    ]
    let fixtures = (Bundle.module.resourceURL ?? Bundle.module.bundleURL).appendingPathComponent("Fixtures")
    let fuzzURL = fixtures.appendingPathComponent("generated/formats-fuzz-v1.5.2.jsonl")
    let lines = try String(contentsOf: fuzzURL, encoding: .utf8).split(separator: "\n")
    for line in lines.dropFirst() {
        guard case let .object(row) = try SchemaValue.parse(json: String(line)),
              case let .array(values)? = row["strings"] else { continue }
        let longest = values.compactMap(\.stringValue).max { $0.utf16.count < $1.utf16.count }
        if let longest { inputs.append(longest) }
    }
    #expect(standardFormats.count == 21)
    let clock = ContinuousClock()
    var slowestName = ""
    var slowestInput = 0
    var slowest: Duration = .zero
    for (inputIndex, input) in inputs.enumerated() {
        for (name, check) in standardFormats {
            let start = clock.now
            _ = check(input)
            let elapsed = start.duration(to: clock.now)
            if elapsed > slowest {
                slowest = elapsed
                slowestName = name
                slowestInput = inputIndex
            }
        }
    }
    print("Slowest hostile format check: \(slowestName), input \(slowestInput), \(inputs[slowestInput].utf16.count) UTF-16 units, \(slowest)")
}

@Test("IDNA script patterns compile on this ICU runtime")
func idnaScriptPatternsCompile() {
    #expect(IdnaPattern.allScriptPatternsCompiled)
    #expect(standardFormatPatternsCompiled)
}

@Test("Punycode label slicing keeps UTF-16 boundaries")
func malformedPunycodeLabel() {
    #expect(standardFormats["hostname"]?("xn--\u{200D}bcher-kva") == false)
}
