import PiSwiftChord

extension JsonlStorage {
    func encodeCommit(seq: Seq, writes: [StorageWrite]) throws -> JsonlEncoded {
        var mainWrites: [JSONValue] = []
        var fileOrder: [String] = []
        var records: [String: [JSONObject]] = [:]
        var nextOrdinal: Int64 = 0
        func addSidecar(file: String, payload: JSONObject) -> Int64 {
            let ordinal = nextOrdinal; nextOrdinal += 1
            if records[file] == nil { fileOrder.append(file); records[file] = [] }
            records[file]!.append(["format": .number(1), "type": .string("record"), "seq": jsonlNumber(seq.rawValue), "ordinal": jsonlNumber(ordinal), "payload": .object(payload)])
            return ordinal
        }
        for write in writes {
            switch write {
            case .conversation, .entry, .submission, .documentRetire:
                mainWrites.append(try JSONValue(encoding: write))
            case .task(let task, _):
                if task.state.status == "terminal" { mainWrites.append(try JSONValue(encoding: write)) }
                else {
                    let ordinal = addSidecar(file: jsonlFile("task", task.id.rawValue), payload: ["type": .string("task"), "value": try JSONValue(encoding: task)])
                    mainWrites.append(.object(["type": .string("task.sidecar"), "id": jsonlNumber(task.id.rawValue), "ordinal": jsonlNumber(ordinal)]))
                }
            case .documentCreate(let record, let content, _):
                let ordinal = addSidecar(file: jsonlFile("doc", record.id.rawValue), payload: ["type": .string("document"), "id": jsonlNumber(record.id.rawValue), "content": try JSONValue(encoding: content)])
                mainWrites.append(.object(["type": .string("document.create"), "record": try JSONValue(encoding: record), "ordinal": jsonlNumber(ordinal)]))
            case .documentChange(let id, let content, _):
                let ordinal = addSidecar(file: jsonlFile("doc", id.rawValue), payload: ["type": .string("document"), "id": jsonlNumber(id.rawValue), "content": try JSONValue(encoding: content)])
                mainWrites.append(.object(["type": .string("document.change"), "id": jsonlNumber(id.rawValue), "ordinal": jsonlNumber(ordinal)]))
            case .documentCopy:
                // Memory preparation always resolves copies before encoding.
                throw jsonlCorruption("Unresolved document copy in prepared commit")
            }
        }
        let marker: JSONObject = ["format": .number(1), "type": .string("commit"), "seq": jsonlNumber(seq.rawValue), "writes": .array(mainWrites)]
        let sidecars = try fileOrder.map { file in
            (file: file, content: try records[file]!.map { try $0.jsonText() + "\n" }.joined())
        }
        return JsonlEncoded(marker: try marker.jsonText() + "\n", sidecars: sidecars)
    }

    func planReclamations(writes: [StorageWrite], encoded: JsonlEncoded) -> [(file: String, content: String)] {
        var created = Set<Int64>(), retired = Set<Int64>(), bases = Set<Int64>()
        var retiredOrder: [Int64] = [], baseOrder: [Int64] = [], taskOrder: [Int64] = []
        var tasks: [Int64: TaskRecord] = [:]
        for write in writes {
            switch write {
            case .documentCreate(let record, _, _):
                if jsonlCurrentOnly(record) { created.insert(record.id.rawValue) }
            case .documentChange(let id, let content, _):
                if case .base = content, bases.insert(id.rawValue).inserted { baseOrder.append(id.rawValue) }
            case .documentRetire(let id, _):
                if retired.insert(id.rawValue).inserted { retiredOrder.append(id.rawValue) }
            case .task(let task, _):
                if tasks[task.id.rawValue] == nil { taskOrder.append(task.id.rawValue) }
                tasks[task.id.rawValue] = task
            default: break
            }
        }
        var replacements: [(file: String, content: String)] = []
        for id in retiredOrder where currentOnlyDocuments.contains(id) || created.contains(id) {
            replacements.append((jsonlFile("doc", id), ""))
        }
        for id in baseOrder where (currentOnlyDocuments.contains(id) || created.contains(id)) && !retired.contains(id) {
            let file = jsonlFile("doc", id)
            if let content = encoded.content(for: file) { replacements.append((file, content)) }
        }
        for id in taskOrder where tasks[id]!.state.status == "terminal" {
            let file = jsonlFile("task", id)
            if liveTaskSidecars.contains(id) || encoded.content(for: file) != nil { replacements.append((file, "")) }
        }
        return replacements
    }
    func adoptSidecarState(writes: [StorageWrite]) {
        for write in writes {
            switch write {
            case .documentCreate(let record, _, _):
                if jsonlCurrentOnly(record) { currentOnlyDocuments.insert(record.id.rawValue) }
            case .task(let task, _):
                if task.state.status == "terminal" { liveTaskSidecars.remove(task.id.rawValue) }
                else { liveTaskSidecars.insert(task.id.rawValue) }
            default: break
            }
        }
    }

    // The marker has published the state. A maintenance failure does not poison it.
    func reclaimSidecars(_ replacements: [(file: String, content: String)], context: ChordContext) async {
        if replacements.isEmpty { return }
        if fsync, case .failure = await fileSystem.flushFile(mainPath, context: context) { return }
        for replacement in replacements {
            guard case .success(let path) = await fileSystem.joinPath([directory, replacement.file], context: context) else { continue }
            if replacement.content.isEmpty {
                _ = await fileSystem.remove(path, options: .init(force: true), context: context)
                continue
            }
            guard case .success(let temporary) = await fileSystem.joinPath([directory, replacement.file + ".reclaim"], context: context) else { continue }
            guard case .success = await fileSystem.writeFile(temporary, content: .text(replacement.content), context: context) else { continue }
            if fsync, case .failure = await fileSystem.flushFile(temporary, context: context) { continue }
            _ = await fileSystem.renameFile(temporary, destinationPath: path, context: context)
        }
    }
}
