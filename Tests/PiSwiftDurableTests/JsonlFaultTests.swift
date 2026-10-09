import Foundation
import Testing
import PiSwiftChord
import PiSwiftDurable
import PiSwiftDurableTesting

typealias JsonlFault = FaultInjectingFileSystem.Failure
private let appendFaults: [JsonlFault] = [
    .init(operation: .append, call: 1, mode: .before), .init(operation: .append, call: 1, mode: .after), .init(operation: .append, call: 1, mode: .short),
    .init(operation: .append, call: 2, mode: .before), .init(operation: .append, call: 2, mode: .after),
    .init(operation: .append, call: 3, mode: .before), .init(operation: .append, call: 3, mode: .short), .init(operation: .append, call: 3, mode: .after),
]
private let flushFaults: [JsonlFault] = [1, 2].flatMap { call in
    [FaultInjectingFileSystem.Mode.before, .after].map { .init(operation: .flush, call: call, mode: $0) }
}
private let reclaimFaults: [JsonlFault] = [
    .init(operation: .write, call: 1, mode: .before), .init(operation: .write, call: 1, mode: .short), .init(operation: .write, call: 1, mode: .after),
    .init(operation: .rename, call: 1, mode: .before), .init(operation: .rename, call: 1, mode: .after),
]
private let removeModes: [FaultInjectingFileSystem.Mode] = [.before, .after]

@Suite("PiSwiftDurableTests.JsonlFaults")
struct JsonlFaultTests {
    @Test(arguments: appendFaults)
    func poisonsAppendAndRecoversConfirmedState(_ fault: JsonlFault) async throws {
        try await jsonlWithStorage { storage, directory, fs in
            try await jsonlRoot(storage)
            let first: DocumentID = try await storage.mintId()
            let second: DocumentID = try await storage.mintId()
            fs.fail(fault)
            try await jsonlExpectError("poisoned") {
                _ = try await storage.commit([jsonlCreate(first, kind: "first", value: ["text": "α"]), jsonlCreate(second, kind: "second", value: ["text": "β"])], context: .background)
            }
            try await jsonlExpectError("poisoned") { _ = try await storage.document(first, at: .current, context: .background) }
            let reopened = try await jsonlOpen(directory)
            let survived = fault.call == 3 && fault.mode == .after
            #expect(try await reopened.document(first, at: .current, context: .background)?.value == (survived ? ["text": "α"] : nil))
            #expect(try await reopened.document(second, at: .current, context: .background)?.value == (survived ? ["text": "β"] : nil))
            try await reopened.close(context: .background)
        }
    }
    @Test(arguments: flushFaults)
    func poisonsFlushAndNeverWritesMarker(_ fault: JsonlFault) async throws {
        try await jsonlWithStorage(fsync: true) { storage, directory, fs in
            try await jsonlRoot(storage)
            let first: DocumentID = try await storage.mintId()
            let second: DocumentID = try await storage.mintId()
            fs.fail(fault)
            try await jsonlExpectError("poisoned") {
                _ = try await storage.commit([jsonlCreate(first, kind: "flush.first", value: [:]), jsonlCreate(second, kind: "flush.second", value: [:])], context: .background)
            }
            #expect(!fs.operations.contains("append:main.jsonl"))
            let reopened = try await jsonlOpen(directory)
            #expect(try await reopened.document(first, at: .current, context: .background) == nil)
            #expect(try await reopened.document(second, at: .current, context: .background) == nil)
            try await reopened.close(context: .background)
        }
    }
    @Test(arguments: reclaimFaults)
    func recoversCommittedBaseAcrossReclaimFault(_ fault: JsonlFault) async throws {
        try await jsonlWithStorage { storage, directory, fs in
            try await jsonlRoot(storage)
            let id: DocumentID = try await storage.mintId()
            _ = try await storage.commit([jsonlCreate(id)], context: .background)
            _ = try await storage.commit([jsonlDelta(id, 1)], context: .background)
            fs.fail(fault)
            #expect(try await storage.commit([jsonlBase(id, 2)], context: .background).rawValue == 4)
            #expect(try await storage.document(id, at: .current, context: .background)?.value == ["count": 2])
            try await storage.close(context: .background)
            let reopened = try await jsonlOpen(directory)
            #expect(try await reopened.document(id, at: .current, context: .background)?.value == ["count": 2])
            #expect(try jsonlLines(directory, jsonlDocName(id)).count == 1)
            try jsonlNoReclaims(directory)
            try await reopened.close(context: .background)
        }
    }
    @Test(arguments: removeModes)
    func recoversDocumentRetirementAcrossRemove(_ mode: FaultInjectingFileSystem.Mode) async throws {
        try await jsonlWithStorage { storage, directory, fs in
            try await jsonlRoot(storage)
            let task: TaskID = try await storage.mintId()
            let id: DocumentID = try await storage.mintId()
            _ = try await storage.commit([.task(value: jsonlTask(task)), jsonlCreate(id, kind: "task.document", value: ["count": 1], scope: .task(taskId: task))], context: .background)
            fs.fail(.init(operation: .remove, call: 1, mode: mode))
            #expect(try await storage.commit([.documentRetire(id: id)], context: .background).rawValue == 3)
            #expect(try await storage.document(id, at: .current, context: .background) == nil)
            try await storage.close(context: .background)
            let reopened = try await jsonlOpen(directory)
            #expect(try await reopened.document(id, at: .current, context: .background) == nil)
            #expect(try await reopened.task(task, context: .background) == jsonlTask(task))
            #expect(!jsonlExists(directory, jsonlDocName(id)))
            try jsonlNoReclaims(directory)
            try await reopened.close(context: .background)
        }
    }
    @Test(arguments: removeModes)
    func defersReclamationAfterMainFlushFailure(_ mode: FaultInjectingFileSystem.Mode) async throws {
        try await jsonlWithStorage(fsync: true) { storage, directory, fs in
            try await jsonlRoot(storage)
            let id: DocumentID = try await storage.mintId()
            let name = jsonlDocName(id)
            _ = try await storage.commit([jsonlCreate(id)], context: .background)
            fs.fail(.init(operation: .flush, call: 2, mode: mode))
            #expect(try await storage.commit([jsonlBase(id, 2)], context: .background).rawValue == 3)
            #expect(fs.operations == ["append:\(name)", "flush:\(name)", "append:main.jsonl", "flush:main.jsonl"])
            #expect(try await storage.document(id, at: .current, context: .background)?.value == ["count": 2])
            #expect(try jsonlLines(directory, name).count == 2)
            try await storage.close(context: .background)
            let recoveryFS = FaultInjectingFileSystem(LocalExecutionEnv(cwd: directory.path))
            recoveryFS.fail(.init(operation: .flush, call: 1, mode: mode))
            let deferred = try await jsonlOpen(directory, fsync: true, fileSystem: recoveryFS)
            #expect(try await deferred.document(id, at: .current, context: .background)?.value == ["count": 2])
            #expect(recoveryFS.operations == ["flush:main.jsonl"])
            #expect(try jsonlLines(directory, name).count == 2)
            try await deferred.close(context: .background)
            let reclaimed = try await jsonlOpen(directory, fsync: true)
            #expect(try await reclaimed.document(id, at: .current, context: .background)?.value == ["count": 2])
            #expect(try jsonlLines(directory, name).count == 1)
            try await reclaimed.close(context: .background)
        }
    }
    @Test(arguments: removeModes)
    func keepsCommittedBaseAfterReclaimTempFlushFailure(_ mode: FaultInjectingFileSystem.Mode) async throws {
        try await jsonlWithStorage(fsync: true) { storage, directory, fs in
            try await jsonlRoot(storage)
            let id: DocumentID = try await storage.mintId()
            _ = try await storage.commit([jsonlCreate(id)], context: .background)
            fs.fail(.init(operation: .flush, call: 3, mode: mode))
            #expect(try await storage.commit([jsonlBase(id, 2)], context: .background).rawValue == 3)
            fs.clear()
            _ = try await storage.commit([jsonlDelta(id, 3)], context: .background)
            try await storage.close(context: .background)
            let reopened = try await jsonlOpen(directory, fsync: true)
            #expect(try await reopened.document(id, at: .current, context: .background)?.value == ["count": 3])
            #expect(try jsonlLines(directory, jsonlDocName(id)).count == 2)
            try await reopened.close(context: .background)
        }
    }
    @Test(arguments: removeModes)
    func recoversTerminalTaskAcrossRemove(_ mode: FaultInjectingFileSystem.Mode) async throws {
        try await jsonlWithStorage { storage, directory, fs in
            try await jsonlRoot(storage)
            let id: TaskID = try await storage.mintId()
            _ = try await storage.commit([.task(value: jsonlTask(id))], context: .background)
            fs.fail(.init(operation: .remove, call: 1, mode: mode))
            #expect(try await storage.commit([.task(value: jsonlTask(id, terminal: true))], context: .background).rawValue == 3)
            #expect(try await storage.task(id, context: .background) == jsonlTask(id, terminal: true))
            try await storage.close(context: .background)
            let reopened = try await jsonlOpen(directory)
            #expect(try await reopened.task(id, context: .background) == jsonlTask(id, terminal: true))
            #expect(!jsonlExists(directory, jsonlTaskName(id)))
            try jsonlNoReclaims(directory)
            try await reopened.close(context: .background)
        }
    }
}
