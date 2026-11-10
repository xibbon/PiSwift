// Differential checks against packages/schema/src/formats at pi-mono v1.5.2.
import Foundation
import Testing
import PiSwiftSchema

private struct FormatVector: Sendable {
    let value: String
    let expected: Bool
}

private struct FormatFixtureRow: Sendable, CustomTestStringConvertible {
    var testDescription: String { format }
    let format: String
    let vectors: [FormatVector]
    let knownRegexDifferences: [FormatVector]
}

private enum FormatFixtureError: Error {
    case invalid(String)
}

// The one recorded URL difference class. Inspect the input host before UTS 46
// mapping, after WHATWG trimming, newline removal, authority parsing, and
// percent decoding. A relative iri-reference uses the fixed HTTP base host.
internal func isUnmappedSpecialHostClass(_ value: String, format: String) -> Bool {
    guard ["url", "iri", "iri-reference"].contains(format) else { return false }
    var units = Array(value.utf16)
    while units.first.map({ $0 <= 0x20 }) == true { units.removeFirst() }
    while units.last.map({ $0 <= 0x20 }) == true { units.removeLast() }
    units.removeAll { $0 == 9 || $0 == 10 || $0 == 13 }
    var colon: Int?
    if let first = units.first, (65...90).contains(first) || (97...122).contains(first) {
        var index = 1
        while index < units.count {
            let unit = units[index]
            if unit == 58 { colon = index; break }
            if !((65...90).contains(unit) || (97...122).contains(unit) ||
                 (48...57).contains(unit) || unit == 43 || unit == 45 || unit == 46) { break }
            index += 1
        }
    }
    let scheme: String
    var tail: [UInt16]
    if let colon {
        scheme = String(decoding: units[..<colon], as: UTF16.self).lowercased()
        tail = Array(units.dropFirst(colon + 1))
    } else {
        guard format == "iri-reference" else { return false }
        scheme = "http"
        tail = units
    }
    guard ["http", "https", "ws", "wss", "ftp", "file"].contains(scheme) else { return false }
    if scheme == "file" {
        guard tail.count >= 2, [47, 92].contains(tail[0]), [47, 92].contains(tail[1]) else { return false }
        tail.removeFirst(2)
    } else {
        if format == "iri-reference" && scheme == "http" && colon != nil &&
            !(tail.count >= 2 && [47, 92].contains(tail[0]) && [47, 92].contains(tail[1])) {
            return false
        }
        while tail.first.map({ [47, 92].contains($0) }) == true { tail.removeFirst() }
    }
    let authority = Array(tail.prefix { ![47, 92, 63, 35].contains($0) })
    guard !authority.isEmpty else { return false }
    let afterCredentials = authority.lastIndex(of: 64).map { Array(authority.dropFirst($0 + 1)) } ?? authority
    guard !afterCredentials.isEmpty, afterCredentials.first != 91 else { return false }
    let hostUnits = Array(afterCredentials.prefix { $0 != 58 })
    guard !hostUnits.isEmpty else { return false }
    let source = Array(String(decoding: hostUnits, as: UTF16.self).utf8)
    var bytes: [UInt8] = []
    var index = 0
    while index < source.count {
        if source[index] == 37 && index + 2 < source.count,
           let hi = UInt8(String(UnicodeScalar(source[index + 1])), radix: 16),
           let lo = UInt8(String(UnicodeScalar(source[index + 2])), radix: 16) {
            bytes.append(hi * 16 + lo)
            index += 3
        } else {
            bytes.append(source[index])
            index += 1
        }
    }
    let hostBytes = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? bytes.dropFirst(3) : bytes[...]
    let host = String(decoding: hostBytes, as: UTF8.self)
    if host.unicodeScalars.contains(where: { $0.value > 127 }) { return true }
    return host.unicodeScalars.split(whereSeparator: { [0x2E, 0xFF0E, 0x3002, 0xFF61].contains($0.value) })
        .contains { label in
            let prefix = Array(label.prefix(4))
            return prefix.count == 4 && (prefix[0].value == 120 || prefix[0].value == 88) &&
                (prefix[1].value == 110 || prefix[1].value == 78) &&
                prefix[2].value == 45 && prefix[3].value == 45
        }
}

private func formatFixtureRows() throws -> [FormatFixtureRow] {
    let fixtures = (Bundle.module.resourceURL ?? Bundle.module.bundleURL).appendingPathComponent("Fixtures")
    let url = fixtures.appendingPathComponent("generated/formats-v1.5.2.jsonl")
    let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
    guard lines.count == 22 else { throw FormatFixtureError.invalid("expected a header and 21 format rows") }
    guard case let .object(header) = try SchemaValue.parse(json: String(lines[0])),
          header["tag"] == .string("v1.5.2"),
          header["generator"] == .string("Scripts/schema-fixtures/generate-format-fixtures.mjs") else {
        throw FormatFixtureError.invalid("provenance header")
    }
    func vectors(_ value: SchemaValue?) throws -> [FormatVector] {
        guard case let .array(items)? = value else { throw FormatFixtureError.invalid("vector array") }
        return try items.map { item in
            guard case let .object(record) = item,
                  case let .string(value)? = record["value"],
                  case let .bool(expected)? = record["expected"] else {
                throw FormatFixtureError.invalid("vector record")
            }
            return FormatVector(value: value, expected: expected)
        }
    }
    let rows = try lines.dropFirst().map { line -> FormatFixtureRow in
        guard case let .object(record) = try SchemaValue.parse(json: String(line)),
              case let .string(format)? = record["format"] else {
            throw FormatFixtureError.invalid("format row")
        }
        let regular = try vectors(record["vectors"])
        let differences = try vectors(record["knownRegexDifferences"])
        guard regular.count >= 60 else { throw FormatFixtureError.invalid("fewer than 60 vectors for \(format)") }
        guard format == "regex" || differences.isEmpty else {
            throw FormatFixtureError.invalid("non-regex difference for \(format)")
        }
        return FormatFixtureRow(format: format, vectors: regular, knownRegexDifferences: differences)
    }
    guard Set(rows.map(\.format)) == Set(standardFormats.keys) else {
        throw FormatFixtureError.invalid("format names do not match standardFormats")
    }
    return rows
}

@Test(arguments: try formatFixtureRows())
private func taggedFormatDifferential(row: FormatFixtureRow) throws {
    guard let check = standardFormats[row.format] else { throw FormatFixtureError.invalid(row.format) }
    for vector in row.vectors {
        #expect(check(vector.value) == vector.expected,
                "\(row.format) value \(String(reflecting: vector.value)): expected \(vector.expected)")
    }
    for vector in row.knownRegexDifferences {
        #expect(check(vector.value) != vector.expected,
                "Known regex difference changed for \(String(reflecting: vector.value))")
    }
}

@Test("seeded fuzz matches Node outside the recorded UTS 46 class", .timeLimit(.minutes(5)))
private func taggedFormatFuzz() throws {
    let fixtures = (Bundle.module.resourceURL ?? Bundle.module.bundleURL).appendingPathComponent("Fixtures")
    let url = fixtures.appendingPathComponent("generated/formats-fuzz-v1.5.2.jsonl")
    let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
    guard lines.count == 22,
          case let .object(header) = try SchemaValue.parse(json: String(lines[0])),
          header["tag"] == .string("v1.5.2"),
          header["seed"] == .number(0x05eed152),
          case let .number(skipped)? = header["skippedLoneSurrogates"], skipped > 0,
          header["generator"] == .string("Scripts/schema-fixtures/generate-format-fixtures.mjs") else {
        throw FormatFixtureError.invalid("fuzz provenance header")
    }
    var totalMismatches = 0
    var unexpectedMismatches = 0
    var unexpectedExamples: [String] = []
    var classTotal = 0
    var classMatches = 0
    let expectedDifferences = ["url": 10, "iri": 4, "iri-reference": 11]
    var names: Set<String> = []
    var mismatchRecords: [String] = []
    let dumpPath = ProcessInfo.processInfo.environment["PI_SCHEMA_FUZZ_DUMP"]
    for line in lines.dropFirst() {
        guard case let .object(row) = try SchemaValue.parse(json: String(line)),
              case let .string(name)? = row["format"],
              case let .array(values)? = row["strings"],
              case let .string(results)? = row["results"],
              let check = standardFormats[name] else {
            throw FormatFixtureError.invalid("fuzz row")
        }
        names.insert(name)
        let bits = Array(results.utf8)
        guard bits.count == values.count,
              values.count >= (["url", "iri", "iri-reference", "uri", "uri-reference", "regex"].contains(name) ? 4_000 : 1_500) else {
            throw FormatFixtureError.invalid("fuzz result count for \(name)")
        }
        var mismatches = 0
        var examples: [String] = []
        var longest = 0
        for (index, item) in values.enumerated() {
            guard case let .string(value) = item, bits[index] == 48 || bits[index] == 49 else {
                throw FormatFixtureError.invalid("fuzz value for \(name)")
            }
            longest = max(longest, value.utf16.count)
            guard longest <= 4_096 else { throw FormatFixtureError.invalid("fuzz string exceeds 4096 UTF-16 units") }
            let expected = bits[index] == 49
            let actual = check(value)
            let inClass = isUnmappedSpecialHostClass(value, format: name)
            if inClass {
                classTotal += 1
                if actual == expected { classMatches += 1 }
            }
            if actual != expected {
                mismatches += 1
                if !inClass || expected || !actual {
                    unexpectedMismatches += 1
                    if unexpectedExamples.count < 30 { unexpectedExamples.append("\(name): \(String(reflecting: value))") }
                }
                if dumpPath != nil {
                    let record: SchemaValue = .object(["format": .string(name), "value": .string(value),
                                                       "expected": .bool(expected), "actual": .bool(actual)])
                    mismatchRecords.append(record.stringify())
                }
                if examples.count < 5 {
                    let display = value.utf16.count > 160 ? String(value.prefix(160)) + "…" : value
                    examples.append("\(String(reflecting: display)) Node=\(expected) Swift=\(actual)")
                }
            }
        }
        if ["url", "iri", "iri-reference", "uri", "uri-reference"].contains(name), longest != 4_096 {
            throw FormatFixtureError.invalid("missing 4096-unit URL family string for \(name)")
        }
        totalMismatches += mismatches
        #expect(mismatches == expectedDifferences[name, default: 0], "difference count changed for \(name)")
        print("FORMAT FUZZ \(name): \(mismatches) mismatches of \(values.count)" +
              (examples.isEmpty ? "" : "\n  " + examples.joined(separator: "\n  ")))
    }
    guard names == Set(standardFormats.keys) else { throw FormatFixtureError.invalid("fuzz format names") }
    if let dumpPath {
        try (mismatchRecords.joined(separator: "\n") + "\n").write(toFile: dumpPath,
                                                                atomically: true, encoding: .utf8)
    }
    print("URL DIFFERENCE CLASS: \(classTotal) strings, \(classMatches) already match Node")
    if !unexpectedExamples.isEmpty { print("OUTSIDE CLASS: \(unexpectedExamples.joined(separator: ", "))") }
    #expect(classTotal == 915, "URL difference class membership changed")
    #expect(classMatches == 890, "URL difference class agreement changed")
    #expect(unexpectedMismatches == 0, "\(unexpectedMismatches) mismatches outside the allowed class or direction")
    #expect(totalMismatches == 25, "seeded format difference count changed")
}

@Test("regex Unicode property aliases match Node 22")
private func regexPropertyAliases() throws {
    let fixtures = (Bundle.module.resourceURL ?? Bundle.module.bundleURL).appendingPathComponent("Fixtures")
    let url = fixtures.appendingPathComponent("generated/regex-properties-node22.json")
    guard case let .object(root) = try SchemaValue.parse(json: Data(contentsOf: url)),
          root["tag"] == .string("v1.5.2"),
          root["nodeMajor"] == .number(22),
          case let .object(decisions)? = root["decisions"],
          let check = standardFormats["regex"] else {
        throw FormatFixtureError.invalid("regex property fixture")
    }
    var count = 0
    var mismatchCount = 0
    var mismatches: [String] = []
    for (_, value) in decisions {
        guard case let .object(group) = value else { throw FormatFixtureError.invalid("property group") }
        for (key, expected) in [("accepted", true), ("rejected", false)] {
            guard case let .array(items)? = group[key] else { throw FormatFixtureError.invalid(key) }
            for item in items {
                guard case let .string(expression) = item else { throw FormatFixtureError.invalid("property expression") }
                count += 1
                let pattern = "\\p{\(expression)}"
                if check(pattern) != expected {
                    mismatchCount += 1
                    if mismatches.count < 5 {
                        mismatches.append("\(String(reflecting: pattern)): Node=\(expected)")
                    }
                }
            }
        }
    }
    #expect(count >= 2_000)
    print("REGEX PROPERTY PROBE: \(mismatchCount) mismatches of \(count) expressions" +
          (mismatches.isEmpty ? "" : "\n  " + mismatches.joined(separator: "\n  ")))
    #expect(mismatchCount == 0, "Regex property differences: \(mismatches.joined(separator: ", "))")
}
