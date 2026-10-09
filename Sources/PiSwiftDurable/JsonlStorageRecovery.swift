import Foundation
import PiSwiftChord

extension JsonlStorage {
    func recover(context: ChordContext) async throws {
        let main = try await readLines(path: mainPath, name: "main.jsonl", context: context) { try jsonlParseMain($0, line: $1) }
        var previousSeq: Int64 = 0
        for line in main.lines {
            guard line.value.seq.rawValue > previousSeq else { throw jsonlCorruption("Commit sequence does not strictly increase in main.jsonl") }
            previousSeq = line.value.seq.rawValue
        }
        let listed = try jsonlFileResult(await fileSystem.listDir(directory, context: context), action: "directory listing")
        for info in listed where info.kind == .file && jsonlSidecarName(info.name, reclaim: true) {
            _ = await fileSystem.remove(info.path, options: .init(force: true), context: context)
        }
        let files = listed.filter { $0.kind == .file && jsonlSidecarName($0.name) }.map(\.name).sorted()
        var parsedFiles: [String: JsonlParsedFile<JsonlRecord>] = [:]
        var records: [JsonlRecordKey: JsonlRecord] = [:]
        for file in files {
            let path = try await resolveFile(file, context: context)
            let parsed = try await readLines(path: path, name: file, context: context) { try jsonlParseSidecar($0, file: file, line: $1) }
            parsedFiles[file] = parsed
            var previous: JsonlRecord?
            for line in parsed.lines {
                let record = line.value
                if let previous, record.seq < previous.seq || (record.seq == previous.seq && record.ordinal <= previous.ordinal) {
                    throw jsonlCorruption("Sidecar records are out of order in \(file)")
                }
                previous = record
                records[.init(file: file, seq: record.seq, ordinal: record.ordinal)] = record
            }
        }
        var currentOnly = Set<Int64>(), retired = Set<Int64>()
        var finalTaskIsLive: [Int64: Bool] = [:]
        for line in main.lines {
            for operation in line.value.writes {
                switch operation["type"]?.stringValue {
                case "document.create":
                    let record = operation["record"]!.objectValue!
                    if record["scope"]?.objectValue?["kind"] != .string("conversation") || record["history"] == .string("latest") {
                        currentOnly.insert(jsonlInteger(record["id"])!)
                    }
                case "document.retire": retired.insert(jsonlInteger(operation["id"])!)
                case "task": finalTaskIsLive[jsonlInteger(operation["value"]!.objectValue!["id"])!] = false
                case "task.sidecar": finalTaskIsLive[jsonlInteger(operation["id"])!] = true
                default: break
                }
            }
        }
        let retiredCurrentOnly = retired.intersection(currentOnly)
        let terminalTasks = Set(finalTaskIsLive.filter { !$0.value }.map(\.key))
        var latestBases: [Int64: JsonlRecord] = [:]
        for line in main.lines {
            let marker = line.value
            for operation in marker.writes {
                guard let type = operation["type"]?.stringValue, type == "document.create" || type == "document.change" else { continue }
                let id = jsonlOperationDocumentID(operation)
                guard currentOnly.contains(id), let record = records[.init(file: jsonlFile("doc", id), seq: marker.seq, ordinal: jsonlInteger(operation["ordinal"])!)],
                      record.payload["type"] == .string("document"), jsonlInteger(record.payload["id"]) == id,
                      record.payload["content"]?.objectValue?["kind"] == .string("base") else { continue }
                if let previous = latestBases[id], !jsonlBefore(previous, record) { continue }
                latestBases[id] = record
            }
        }
        var confirmed = Set<JsonlRecordKey>()
        for line in main.lines {
            let marker = line.value
            var writes: [StorageWrite] = []
            // Decode and validate replay inside the same error boundary as memory preparation.
            // Sidecar confirmation errors keep their specific diagnostic texts.
            var replayObjects: [JSONObject] = []
            for operation in marker.writes {
                switch operation["type"]!.stringValue! {
                case "conversation", "entry", "submission", "task", "document.retire":
                    replayObjects.append(operation)
                case "task.sidecar":
                    let id = jsonlInteger(operation["id"])!
                    let optional = terminalTasks.contains(id)
                    let key = JsonlRecordKey(file: jsonlFile("task", id), seq: marker.seq, ordinal: jsonlInteger(operation["ordinal"])!)
                    if let record = try jsonlConfirm(key, records: records, confirmed: &confirmed, optional: optional) {
                        guard record.payload["type"] == .string("task"), jsonlInteger(record.payload["value"]?.objectValue?["id"]) == id else {
                            throw jsonlCorruption("Confirmed task sidecar data does not match commit \(marker.seq.rawValue)")
                        }
                        if !optional { replayObjects.append(["type": .string("task"), "value": record.payload["value"]!]) }
                    }
                case "document.create", "document.change":
                    let id = jsonlOperationDocumentID(operation)
                    let ordinal = jsonlInteger(operation["ordinal"])!
                    let reclaimed = retiredCurrentOnly.contains(id) || jsonlBeforeBase(latestBases[id], marker.seq, ordinal)
                    let key = JsonlRecordKey(file: jsonlFile("doc", id), seq: marker.seq, ordinal: ordinal)
                    let record = try jsonlConfirm(key, records: records, confirmed: &confirmed, optional: reclaimed)
                    var content: JSONValue?
                    if let record {
                        guard record.payload["type"] == .string("document"), jsonlInteger(record.payload["id"]) == id else {
                            throw jsonlCorruption("Confirmed document sidecar data does not match commit \(marker.seq.rawValue)")
                        }
                        content = record.payload["content"]
                    }
                    if operation["type"] == .string("document.create") {
                        if let content, content.objectValue?["kind"] != .string("base") {
                            throw jsonlCorruption("Document creation lacks a confirmed base in commit \(marker.seq.rawValue)")
                        }
                        let empty: JSONValue = .object(["kind": .string("base"), "version": .number(1), "value": .object([:])])
                        replayObjects.append(["type": .string("document.create"), "record": operation["record"]!, "content": reclaimed ? empty : (content ?? empty)])
                    } else if !reclaimed, let content {
                        replayObjects.append(["type": .string("document.change"), "id": jsonlNumber(id), "content": content])
                    }
                default: break // Main parsing rejects an unknown type.
                }
            }
            do {
                writes = try replayObjects.map { try JSONValue.object($0).decode(StorageWrite.self) }
                let prepared = try await memory.prepareCommit(writes, seq: marker.seq)
                _ = await prepared.apply()
            } catch { throw JsonlCorruptionError(message: "Invalid committed state at sequence \(marker.seq.rawValue)", cause: error) }
        }
        var replacements: [(file: String, content: String)] = []
        for file in files {
            let parsed = parsedFiles[file]!
            var unconfirmedAt: Int64?
            var confirmedLines: [JsonlLine<JsonlRecord>] = []
            for line in parsed.lines {
                let record = line.value
                if confirmed.contains(.init(file: file, seq: record.seq, ordinal: record.ordinal)) {
                    if unconfirmedAt != nil { throw jsonlCorruption("Confirmed record follows an unconfirmed tail in \(file)") }
                    confirmedLines.append(line)
                } else if unconfirmedAt == nil { unconfirmedAt = line.start }
            }
            if let unconfirmedAt {
                try jsonlFileResult(await fileSystem.truncateFile(parsed.path, size: unconfirmedAt, context: context), action: "tail truncation of \(file)")
            }
            // A filename can contain a number outside the safe ID range. It remains a parsed
            // unconfirmed sidecar; no metadata or reclamation rule can refer to that number.
            let start = file.index(after: file.firstIndex(of: "-")!)
            let end = file.index(file.endIndex, offsetBy: -6)
            let id = Int64(file[start..<end])
            var retained: [JsonlLine<JsonlRecord>]?
            if let id, file.hasPrefix("task-"), terminalTasks.contains(id) { retained = [] }
            else if let id, file.hasPrefix("doc-") {
                if retiredCurrentOnly.contains(id) { retained = [] }
                else if latestBases[id] != nil { retained = confirmedLines.filter { !jsonlBeforeBase(latestBases[id], $0.value.seq, $0.value.ordinal) } }
            }
            if let retained, retained.count < confirmedLines.count || retained.isEmpty {
                replacements.append((file, try retained.map { try $0.value.object.jsonText() + "\n" }.joined()))
            }
        }
        await reclaimSidecars(replacements, context: context)
        currentOnlyDocuments = currentOnly
        liveTaskSidecars = Set(finalTaskIsLive.filter(\.value).map(\.key))
    }

    func readLines<Value: Sendable>(path: String, name: String, context: ChordContext, parse: (String, Int) throws -> Value) async throws -> JsonlParsedFile<Value> {
        let bytes: [UInt8]
        switch await fileSystem.readBinaryFile(path, context: context) {
        case .success(let value): bytes = value
        case .failure(let error):
            if error.code == .notFound { return .init(path: path, lines: []) }
            throw JsonlFileError(action: "read of \(name)", cause: error)
        }
        var completeSize = bytes.count
        if completeSize > 0, bytes[completeSize - 1] != 0x0a {
            completeSize = bytes.lastIndex(of: 0x0a).map { $0 + 1 } ?? 0
            try jsonlFileResult(await fileSystem.truncateFile(path, size: Int64(completeSize), context: context), action: "torn-line truncation of \(name)")
        }
        var lines: [JsonlLine<Value>] = []
        var start = 0, lineNumber = 1
        for end in 0..<completeSize where bytes[end] == 0x0a {
            var textStart = start
            // TextDecoder strips one initial UTF-8 BOM on each decode call.
            if end - start >= 3, bytes[start] == 0xef, bytes[start + 1] == 0xbb, bytes[start + 2] == 0xbf { textStart += 3 }
            guard let text = String(bytes: bytes[textStart..<end], encoding: .utf8) else {
                throw jsonlCorruption("Invalid UTF-8 in complete \(name) line \(lineNumber)")
            }
            lines.append(.init(value: try parse(text, lineNumber), start: Int64(start)))
            start = end + 1; lineNumber += 1
        }
        return .init(path: path, lines: lines)
    }
}

private func jsonlOperationDocumentID(_ operation: JSONObject) -> Int64 {
    operation["type"] == .string("document.create")
        ? jsonlInteger(operation["record"]!.objectValue!["id"])!
        : jsonlInteger(operation["id"])!
}
private func jsonlBefore(_ a: JsonlRecord, _ b: JsonlRecord) -> Bool {
    a.seq < b.seq || (a.seq == b.seq && a.ordinal < b.ordinal)
}
private func jsonlConfirm(_ key: JsonlRecordKey, records: [JsonlRecordKey: JsonlRecord], confirmed: inout Set<JsonlRecordKey>, optional: Bool) throws -> JsonlRecord? {
    if confirmed.contains(key) { throw jsonlCorruption("Sidecar record is confirmed more than once") }
    guard let record = records[key] else {
        if optional { return nil }
        throw jsonlCorruption("Missing confirmed sidecar record \(key.file) at sequence \(key.seq.rawValue)")
    }
    confirmed.insert(key)
    return record
}

private func jsonlBeforeBase(_ base: JsonlRecord?, _ seq: Seq, _ ordinal: Int64) -> Bool {
    guard let base else { return false }
    return seq < base.seq || (seq == base.seq && ordinal < base.ordinal)
}
