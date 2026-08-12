import Foundation
import PiSwiftAI

public actor InMemoryCodingAgentModelsStore: ModelsStore {
    private var entries: [String: ModelsStoreEntry]

    public init(entries: [String: ModelsStoreEntry] = [:]) {
        self.entries = entries
    }

    public func read(providerId: String, signal: CancellationToken? = nil) async throws -> ModelsStoreEntry? {
        try checkCancellation(signal)
        return entries[providerId]
    }

    public func write(
        providerId: String,
        entry: ModelsStoreEntry,
        signal: CancellationToken? = nil
    ) async throws {
        try checkCancellation(signal)
        entries[providerId] = entry
    }

    public func delete(providerId: String, signal: CancellationToken? = nil) async throws {
        try checkCancellation(signal)
        entries.removeValue(forKey: providerId)
    }
}

private struct ModelsFileRevision: Sendable, Equatable {
    var modificationTime: Double
    var size: UInt64
    var fileNumber: UInt64
}

private struct ModelsFileReloadResult: Sendable {
    var data: [String: ModelsStoreEntry]
    var revision: ModelsFileRevision?
}

private struct ModelsFileReload: Sendable {
    var id: UUID
    var signal: CancellationToken
    var task: Task<ModelsFileReloadResult, Error>
    var readers: Int
}

private actor ModelsFileReadState {
    private var data: [String: ModelsStoreEntry] = [:]
    private var revision: ModelsFileRevision?
    private var reload: ModelsFileReload?

    func readLatest(
        path: String,
        storage: any AuthStorageBackend,
        signal: CancellationToken?
    ) async throws -> [String: ModelsStoreEntry] {
        try checkCancellation(signal)
        let currentRevision = modelsFileRevision(path)
        if let currentRevision, currentRevision == revision {
            return data
        }

        let handle: ModelsFileReload
        if var current = reload {
            current.readers += 1
            reload = current
            handle = current
        } else {
            let reloadSignal = CancellationToken()
            let task = Task<ModelsFileReloadResult, Error> {
                try await storage.withLockAsync(signal: reloadSignal) { content in
                    try checkCancellation(reloadSignal)
                    let parsed = try parseStoredModels(content)
                    return AuthStorageLockResult(
                        result: ModelsFileReloadResult(
                            data: parsed,
                            revision: modelsFileRevision(path)
                        )
                    )
                }
            }
            handle = ModelsFileReload(id: UUID(), signal: reloadSignal, task: task, readers: 1)
            reload = handle
        }

        do {
            let result = try await awaitModelsReload(handle.task, signal: signal)
            try checkCancellation(signal)
            finishReload(handle.id, result: result)
            return result.data
        } catch {
            leaveReload(handle.id)
            throw error
        }
    }

    func updateAfterMutation(_ latest: [String: ModelsStoreEntry]) {
        data = latest
        // Force the next read to compare against storage. This also prevents a late
        // cache update from one writer from hiding a newer writer's commit.
        revision = nil
    }

    private func finishReload(_ id: UUID, result: ModelsFileReloadResult) {
        guard reload?.id == id else { return }
        data = result.data
        revision = result.revision
        reload = nil
    }

    private func leaveReload(_ id: UUID) {
        guard var current = reload, current.id == id else { return }
        current.readers -= 1
        if current.readers == 0 {
            reload = nil
            current.signal.cancel()
            current.task.cancel()
        } else {
            reload = current
        }
    }
}

private struct SharedModelsFileReadState: Sendable {
    var path: String?
    var state: ModelsFileReadState?
}

private let sharedModelsFileReadState = LockedState(SharedModelsFileReadState())

/// Locked JSON-backed storage for dynamically refreshed provider catalogs.
public final class FileModelsStore: ModelsStore {
    public let path: String
    private let storage: any AuthStorageBackend
    private let readState: ModelsFileReadState

    public convenience init(_ path: String = (getAgentDir() as NSString).appendingPathComponent("models-store.json")) {
        self.init(path: path, storage: FileAuthStorageBackend(path))
    }

    public init(path: String, storage: any AuthStorageBackend) {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        self.path = normalizedPath
        self.storage = storage
        self.readState = sharedModelsFileReadState.withLock { shared in
            if shared.path == normalizedPath, let state = shared.state {
                return state
            }
            let state = ModelsFileReadState()
            if shared.path == nil {
                shared.path = normalizedPath
                shared.state = state
            }
            return state
        }
    }

    public func read(providerId: String, signal: CancellationToken? = nil) async throws -> ModelsStoreEntry? {
        let entry = try await readState.readLatest(path: path, storage: storage, signal: signal)[providerId]
        try checkCancellation(signal)
        return entry
    }

    public func write(
        providerId: String,
        entry: ModelsStoreEntry,
        signal: CancellationToken? = nil
    ) async throws {
        let latest = try await storage.withLockAsync(signal: signal) { content in
            try checkCancellation(signal)
            var current = try parseStoredModels(content)
            current[providerId] = entry
            try checkCancellation(signal)
            return AuthStorageLockResult(result: current, next: try encodeStoredModels(current))
        }
        try checkCancellation(signal)
        await readState.updateAfterMutation(latest)
    }

    public func delete(providerId: String, signal: CancellationToken? = nil) async throws {
        let latest = try await storage.withLockAsync(signal: signal) { content in
            try checkCancellation(signal)
            var current = try parseStoredModels(content)
            current.removeValue(forKey: providerId)
            try checkCancellation(signal)
            return AuthStorageLockResult(result: current, next: try encodeStoredModels(current))
        }
        try checkCancellation(signal)
        await readState.updateAfterMutation(latest)
    }
}

private func parseStoredModels(_ content: String?) throws -> [String: ModelsStoreEntry] {
    guard let content, !content.isEmpty else { return [:] }
    return try JSONDecoder().decode([String: ModelsStoreEntry].self, from: Data(content.utf8))
}

private func encodeStoredModels(_ entries: [String: ModelsStoreEntry]) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let encoded = try encoder.encode(entries)
    guard let value = String(data: encoded, encoding: .utf8) else {
        throw OAuthError.refreshFailed("failed to encode model storage")
    }
    return value
}

private func modelsFileRevision(_ path: String) -> ModelsFileRevision? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
          let modificationDate = attributes[.modificationDate] as? Date,
          let size = (attributes[.size] as? NSNumber)?.uint64Value else {
        return nil
    }
    return ModelsFileRevision(
        modificationTime: modificationDate.timeIntervalSince1970,
        size: size,
        fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    )
}

private func awaitModelsReload<T: Sendable>(
    _ task: Task<T, Error>,
    signal: CancellationToken?
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await task.value }
        if let signal {
            group.addTask {
                while true {
                    try await abortableSleep(ms: 60_000, signal: signal)
                }
            }
        }
        defer { group.cancelAll() }
        guard let value = try await group.next() else {
            throw OAuthError.cancelled
        }
        return value
    }
}

@inline(__always)
private func checkCancellation(_ signal: CancellationToken?) throws {
    if signal?.isCancelled == true || Task.isCancelled {
        throw OAuthError.cancelled
    }
}
