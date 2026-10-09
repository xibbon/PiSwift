import Testing
import PiSwiftChord

private func regionChild(_ draft: JSONDraft, _ key: String) throws -> JSONDraft { try #require(try draft.child(key)) }
private func regionChild(_ draft: JSONDraft, _ index: Int) throws -> JSONDraft { try #require(try draft.child(index)) }
private func regionReplay(_ prepared: Delta.Prepared) throws {
    #expect(try Delta.applyImmutable(prepared.base, prepared.ops) == prepared.value)
}

@Suite struct TrackerRegionTests {
    @Test func foldsDenseChildAndDirectIndexEdits() throws {
        let tracker = try Delta.track(["rows": .array((0..<1_000).map { ["value": .number(Double($0))] })])
        let change = tracker.beginChange()
        let rows = try regionChild(change.state, "rows")
        for index in 0..<1_000 { try regionChild(rows, index).set("value", .number(Double(index + 1))) }
        let prepared = try change.prepare()
        #expect(prepared.ops.count == 1)
        #expect(prepared.ops.first?.json.arrayValue?.first == "p")
        try regionReplay(prepared)
        let valuesTracker = try Delta.track(["values": .array((0..<1_000).map { .number(Double($0)) })])
        let valuesChange = valuesTracker.beginChange()
        let values = try regionChild(valuesChange.state, "values")
        for index in 0..<600 { try values.set(index, .number(Double(-index - 1))) }
        let valuesPrepared = try valuesChange.prepare()
        #expect(valuesPrepared.ops.count == 1)
        #expect(valuesPrepared.ops.first?.json.arrayValue?.first == "p")
        try regionReplay(valuesPrepared)
    }

    @Test func foldsOnlyDeeplyNestedDenseRegion() throws {
        let tracker = try Delta.track(["rows": .array((0..<2_000).map { ["nested": ["value": .number(Double($0))]] })])
        let change = tracker.beginChange()
        let rows = try regionChild(change.state, "rows")
        try regionChild(regionChild(rows, 0), "nested").set("value", -1)
        for index in 500..<1_000 { try regionChild(regionChild(rows, index), "nested").set("value", .number(Double(-index))) }
        let prepared = try change.prepare()
        let splice = try #require(prepared.ops.first { $0.json.arrayValue?.first == "p" })
        #expect(Array(try #require(splice.json.arrayValue).prefix(4)) == ["p", ["rows"], 500, 500])
        #expect(splice.json[4]?.arrayValue?.count == 500)
        #expect(prepared.ops.count == 2)
        try regionReplay(prepared)
    }

    @Test func outerDenseRegionCoversReservedKeyFolds() throws {
        var rows: [JSONValue] = (0..<400).map { _ in ["flag": 0] }
        rows[100] = ["flag": 0, "special": ["__proto__": ["values": .array((0..<400).map { .number(Double($0)) })]]]
        let tracker = try Delta.track(["rows": .array(rows)])
        let change = tracker.beginChange()
        let draftRows = try regionChild(change.state, "rows")
        for index in 0..<256 { try regionChild(draftRows, index).set("flag", 1) }
        let nested = try regionChild(regionChild(regionChild(regionChild(draftRows, 100), "special"), "__proto__"), "values")
        for index in 0..<256 { try nested.set(index, .number(Double(-index - 1))) }
        let prepared = try change.prepare()
        #expect(prepared.ops.count == 1)
        #expect(Array(try #require(prepared.ops.first?.json.arrayValue).prefix(4)) == ["p", ["rows"], 0, 256])
        try regionReplay(prepared)
    }

    @Test func outerDenseRegionSuppressesNestedStructuralAndLeafOps() throws {
        let rows: [JSONValue] = (0..<400).map { index in
            ["flag": 0, "values": .array(index == 100 ? (0..<400).map { ["value": .number(Double($0))] } : [])]
        }
        let tracker = try Delta.track(["rows": .array(rows)])
        let change = tracker.beginChange()
        let draftRows = try regionChild(change.state, "rows")
        for index in 0..<256 { try regionChild(draftRows, index).set("flag", 1) }
        let nested = try regionChild(regionChild(draftRows, 100), "values")
        for index in 0..<256 { try regionChild(nested, index).set("value", .number(Double(-index - 1))) }
        try nested.append(["value": 999])
        let prepared = try change.prepare()
        #expect(prepared.ops.count == 1)
        #expect(Array(try #require(prepared.ops.first?.json.arrayValue).prefix(4)) == ["p", ["rows"], 0, 256])
        #expect(prepared.value["rows"]?[100]?["values"]?.arrayValue?.count == 401)
        try regionReplay(prepared)
    }

    @Test func emitsDisjointDenseRegionsAndOutsideLeafOps() throws {
        let tracker = try Delta.track(["values": .array((0..<1_400).map { ["value": .number(Double($0))] })])
        let change = tracker.beginChange()
        let values = try regionChild(change.state, "values")
        let outside = [97, 358, 897, 1_158]
        for index in outside + Array(100..<356) + Array(900..<1_156) {
            try regionChild(values, index).set("value", .number(Double(-index - 1)))
        }
        let prepared = try change.prepare()
        let splices = prepared.ops.filter { $0.json.arrayValue?.first == "p" }
        #expect(try splices.map { Array(try #require($0.json.arrayValue).prefix(4)) } == [["p", ["values"], 100, 256], ["p", ["values"], 900, 256]])
        for index in outside { #expect(prepared.ops.contains(.set(["values", .index(index), "value"], .number(Double(-index - 1))))) }
        #expect(prepared.ops.count == 6)
        try regionReplay(prepared)
    }

    @Test func foldsPathologicalOpCountsForObjectsAndSparseArrays() throws {
        var wide = JSONObject()
        for index in 0..<5_000 { wide["field\(index)"] = 0 }
        let tracker = try Delta.track(.object(wide))
        let change = tracker.beginChange()
        for index in 0..<5_000 { try change.state.set("field\(index)", 1) }
        let prepared = try change.prepare()
        #expect(prepared.ops == [.replace(prepared.value)])
        try regionReplay(prepared)
        let sparseTracker = try Delta.track(["rows": .array((0..<15_000).map { ["value": .number(Double($0))] })])
        let sparseChange = sparseTracker.beginChange()
        let rows = try regionChild(sparseChange.state, "rows")
        for index in stride(from: 0, to: 15_000, by: 3) { try regionChild(rows, index).set("value", .number(Double(-index - 1))) }
        let sparsePrepared = try sparseChange.prepare()
        #expect(sparsePrepared.ops == [.replace(sparsePrepared.value)])
        try regionReplay(sparsePrepared)
    }
}
