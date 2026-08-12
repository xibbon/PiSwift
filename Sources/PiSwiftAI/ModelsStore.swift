import Foundation

public struct ModelsStoreEntry: Sendable, Codable {
    public var models: [Model]
    /// Unix milliseconds from the remote catalog's Last-Modified header.
    public var lastModified: Double?
    /// Unix milliseconds of the last completed remote check.
    public var checkedAt: Double?
    /// Opaque ETag validator, including quotes when the server supplied them.
    public var etag: String?

    public init(
        models: [Model],
        lastModified: Double? = nil,
        checkedAt: Double? = nil,
        etag: String? = nil
    ) {
        self.models = models
        self.lastModified = lastModified
        self.checkedAt = checkedAt
        self.etag = etag
    }
}

public protocol ModelsStore: Sendable {
    func read(providerId: String, signal: CancellationToken?) async throws -> ModelsStoreEntry?
    func write(providerId: String, entry: ModelsStoreEntry, signal: CancellationToken?) async throws
    func delete(providerId: String, signal: CancellationToken?) async throws
}

public actor InMemoryModelsStore: ModelsStore {
    private var entries: [String: ModelsStoreEntry]

    public init(entries: [String: ModelsStoreEntry] = [:]) {
        self.entries = entries
    }

    public func read(providerId: String, signal: CancellationToken? = nil) async throws -> ModelsStoreEntry? {
        try checkModelsStoreCancellation(signal)
        return entries[providerId]
    }

    public func write(
        providerId: String,
        entry: ModelsStoreEntry,
        signal: CancellationToken? = nil
    ) async throws {
        try checkModelsStoreCancellation(signal)
        entries[providerId] = entry
    }

    public func delete(providerId: String, signal: CancellationToken? = nil) async throws {
        try checkModelsStoreCancellation(signal)
        entries.removeValue(forKey: providerId)
    }
}

@inline(__always)
func checkModelsStoreCancellation(_ signal: CancellationToken?) throws {
    if signal?.isCancelled == true || Task.isCancelled {
        throw StreamError.requestAborted
    }
}
