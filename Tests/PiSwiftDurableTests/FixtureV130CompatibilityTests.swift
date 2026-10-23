import Foundation
import Testing
import PiSwiftChord

@Suite struct FixtureV130CompatibilityTests {
    private func fixture(_ name: String) throws -> JSONValue {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try JSONValue(jsonData: Data(contentsOf: url))
    }

    // Existing tests execute all these legacy cases against Swift. Compare the
    // v1.3 oracle data in full to keep their tag and diff-version checks intact.
    @Test func readTagPreservesAllSeededResults() throws {
        let previous = try fixture("read-differential")
        let current = try fixture("read-differential-v130")
        #expect(current["tag"] == "v1.3.0")
        #expect(current["provenance"]?["resultEnvelope"] == "top-level output renamed to content for current Swift tests")
        for key in ["seeds", "trialsPerSeed", "differences", "files"] {
            #expect(current[key] == previous[key], "read field \(key)")
        }
    }

    @Test func pinnedEditDependencyPreservesEveryExpectedResult() throws {
        let previous = try fixture("edit-fixtures")
        let current = try fixture("edit-fixtures-v130")
        #expect(current["tag"] == "v1.3.0")
        #expect(current["diffVersion"] == "8.0.4")
        #expect(current["provenance"]?["dependency"] == "isolated npm diff@8.0.4")
        for key in ["edits", "diffs", "normalization", "counts"] {
            #expect(current[key] == previous[key], "edit field \(key)")
        }
    }
}
