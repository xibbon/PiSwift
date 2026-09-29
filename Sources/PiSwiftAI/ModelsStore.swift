import Foundation

public struct ModelsStoreEntry: Sendable, Codable {
    public var models: [AnyModel]
    /// Unix milliseconds from the remote catalog's Last-Modified header.
    public var lastModified: Double?
    /// Unix milliseconds of the last completed remote check.
    public var checkedAt: Double?
    /// Opaque ETag validator, including quotes when the server supplied them.
    public var etag: String?

    @_disfavoredOverload
    public init(
        models: [AnyModel],
        lastModified: Double? = nil,
        checkedAt: Double? = nil,
        etag: String? = nil
    ) {
        self.models = models
        self.lastModified = lastModified
        self.checkedAt = checkedAt
        self.etag = etag
    }

    public init(models: [Model], lastModified: Double? = nil,
                checkedAt: Double? = nil, etag: String? = nil) {
        self.init(models: models.map(AnyModel.chat), lastModified: lastModified,
                  checkedAt: checkedAt, etag: etag)
    }

    private enum CodingKeys: String, CodingKey { case models, lastModified, checkedAt, etag }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        lastModified = try fields.decodeIfPresent(Double.self, forKey: .lastModified)
        checkedAt = try fields.decodeIfPresent(Double.self, forKey: .checkedAt)
        etag = try fields.decodeIfPresent(String.self, forKey: .etag)
        var values = try fields.nestedUnkeyedContainer(forKey: .models)
        var decoded: [AnyModel] = []
        while !values.isAtEnd {
            let item = try values.superDecoder()
            if let model = try? AnyModel(from: item) { decoded.append(model) }
        }
        models = decoded
    }

    public func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(models, forKey: .models)
        try fields.encodeIfPresent(lastModified, forKey: .lastModified)
        try fields.encodeIfPresent(checkedAt, forKey: .checkedAt)
        try fields.encodeIfPresent(etag, forKey: .etag)
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
