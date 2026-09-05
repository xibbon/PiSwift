import Foundation
import PiSwiftAI

public let REMOTE_CATALOG_REFRESH_INTERVAL_MS = 4 * 60 * 60 * 1_000.0

public enum RemoteCatalogError: Error, LocalizedError, Sendable {
    case invalidBaseURL(String)
    case invalidCatalog(String)
    case requestFailed(providerId: String, statusCode: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let value):
            return "Invalid model catalog base URL: \(value)"
        case .invalidCatalog(let providerId):
            return "Invalid model catalog for provider \"\(providerId)\""
        case .requestFailed(let providerId, let statusCode):
            return "Model catalog request failed for \(providerId): \(statusCode)"
        }
    }
}

public struct ManagementHTTPResponse: Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

public struct FetchRetryOptions: Sendable {
    public var maxRetries: Int
    public var retryOnStatus: Bool
    /// Overall time budget shared by all attempts.
    public var timeoutMs: Double?
    /// A new timeout starts for each attempt. Expiry permits a retry.
    public var attemptTimeoutMs: Double?

    public init(maxRetries: Int = 2, retryOnStatus: Bool = true, timeoutMs: Double? = nil, attemptTimeoutMs: Double? = nil) {
        self.maxRetries = max(0, maxRetries)
        self.retryOnStatus = retryOnStatus
        self.timeoutMs = timeoutMs
        self.attemptTimeoutMs = attemptTimeoutMs
    }
}

/// Fetches an idempotent management resource with bounded immediate retries.
public func fetchWithRetry(
    _ request: URLRequest,
    client: any ProviderHTTPClient = DefaultProviderHTTPClient(),
    options: FetchRetryOptions = .init(),
    signal: CancellationToken? = nil
) async throws -> ManagementHTTPResponse {
    let retryableStatuses: Set<Int> = [408, 425, 429, 500, 502, 503, 504]
    let retryLimit = options.maxRetries
    let attempts = LockedState(0)
    let effectiveSignal = CancellationToken()
    if signal?.isCancelled == true { effectiveSignal.cancel() }
    let parentMonitor = managementCancellationMonitor(parent: signal, child: effectiveSignal)
    let timeoutTask: Task<Void, Never>? = if let timeoutMs = options.timeoutMs, timeoutMs > 0 {
        Task {
            do {
                try await Task.sleep(for: .milliseconds(timeoutMs))
                effectiveSignal.cancel()
            } catch {}
        }
    } else {
        nil
    }
    defer {
        parentMonitor?.cancel()
        timeoutTask?.cancel()
    }

    return try await retryProviderRequest(
        maxRetries: retryLimit,
        maxRetryDelayMs: 0,
        signal: effectiveSignal
    ) {
        let attempt = attempts.withLock { value -> Int in
            value += 1
            return value
        }
        let attemptSignal = CancellationToken()
        let attemptTimeoutTask: Task<Void, Never>? = if let timeout = options.attemptTimeoutMs, timeout > 0 {
            Task {
                do {
                    try await Task.sleep(for: .milliseconds(timeout))
                    attemptSignal.cancel()
                } catch {}
            }
        } else { nil }
        defer { attemptTimeoutTask?.cancel() }
        do {
            let response = try await retryProviderRequest(maxRetries: 0, signal: attemptSignal) {
                let response = try await client.send(request)
                var body = Data()
                for try await chunk in response.body { body.append(chunk) }
                return ManagementHTTPResponse(statusCode: response.statusCode, headers: response.headers, body: body)
            }
            if options.retryOnStatus,
               retryableStatuses.contains(response.statusCode),
               attempt <= retryLimit {
                throw StreamError.providerRequest(
                    // A nil status lets the shared provider policy retry every management
                    // status above, including 425.
                    statusCode: nil,
                    headers: ["retry-after-ms": "0"],
                    message: "HTTP \(response.statusCode)"
                )
            }
            return ManagementHTTPResponse(
                statusCode: response.statusCode,
                headers: response.headers,
                body: response.body
            )
        } catch {
            if effectiveSignal.isCancelled || Task.isCancelled {
                throw StreamError.requestAborted
            }
            if !attemptSignal.isCancelled {
                if (error as? URLError)?.code == .cancelled || error is CancellationError { throw error }
                if case .requestAborted = error as? StreamError, options.timeoutMs == nil { throw error }
            }
            if attempt <= retryLimit {
                throw StreamError.providerRequest(
                    statusCode: nil,
                    headers: ["retry-after-ms": "0"],
                    message: error.localizedDescription
                )
            }
            throw error
        }
    }
}

private func managementCancellationMonitor(
    parent: CancellationToken?,
    child: CancellationToken
) -> Task<Void, Never>? {
    guard let parent else { return nil }
    return Task {
        do {
            while true {
                try await abortableSleep(ms: 60_000, signal: parent)
            }
        } catch {
            child.cancel()
        }
    }
}

/// Refresh implementation for one built-in provider's pi.dev catalog overlay.
public struct RemoteCatalogProvider: Sendable {
    public let providerId: String
    private let catalogBaseURL: String
    private let localGeneratedAt: Double?
    private let httpClient: any ProviderHTTPClient
    private let now: @Sendable () -> Double
    private let updateOverlay: @Sendable ([Model]) -> Void

    public init(
        providerId: String,
        catalogBaseURL: String = "https://pi.dev",
        localGeneratedAt: Double? = getBuiltinModelDataGeneratedAt(),
        httpClient: any ProviderHTTPClient = DefaultProviderHTTPClient(),
        now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1_000 },
        updateOverlay: @escaping @Sendable ([Model]) -> Void
    ) {
        self.providerId = providerId
        self.catalogBaseURL = catalogBaseURL
        self.localGeneratedAt = localGeneratedAt
        self.httpClient = httpClient
        self.now = now
        self.updateOverlay = updateOverlay
    }

    public func refresh(_ context: RefreshModelsContext) async throws {
        let stored = context.stored
        let restored = remoteModels(stored).filter { $0.provider == providerId }
        guard await context.publish(ModelsPublication(update: {
            updateOverlay(restored)
        })) else { return }

        guard context.allowNetwork, !context.signal.isCancelled else { return }
        if !context.force,
           let checkedAt = stored?.checkedAt,
           stored?.lastModified != nil,
           now() - checkedAt < REMOTE_CATALOG_REFRESH_INTERVAL_MS {
            return
        }

        let encodedProvider = providerId.addingPercentEncoding(
            withAllowedCharacters: CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        ) ?? providerId
        let trimmedBase = catalogBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(trimmedBase)/api/models/providers/\(encodedProvider)") else {
            throw RemoteCatalogError.invalidBaseURL(catalogBaseURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(piUserAgent(version: VERSION), forHTTPHeaderField: "User-Agent")
        if stored?.models.isEmpty == false, let etag = stored?.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let response = try await fetchWithRetry(request, client: httpClient, options: .init(attemptTimeoutMs: 4_000), signal: context.signal)
        if context.signal.isCancelled { return }
        let checkedAt = now()

        if response.statusCode == 304, var stored {
            stored.checkedAt = checkedAt
            _ = await context.publish(ModelsPublication(persist: .write(stored)))
            return
        }

        if response.statusCode == 404 || response.statusCode == 501 {
            var entry = stored ?? ModelsStoreEntry(models: [])
            entry.checkedAt = checkedAt
            entry.lastModified = 0
            entry.etag = nil
            _ = await context.publish(ModelsPublication(persist: .write(entry)))
            return
        }

        guard (200..<300).contains(response.statusCode) else {
            var entry = stored ?? ModelsStoreEntry(models: [])
            entry.checkedAt = checkedAt
            guard await context.publish(ModelsPublication(persist: .write(entry))) else { return }
            throw RemoteCatalogError.requestFailed(
                providerId: providerId,
                statusCode: response.statusCode
            )
        }

        let refreshed = try parseCatalog(response.body)
        let entry = ModelsStoreEntry(
            models: refreshed,
            lastModified: parseHTTPDateMilliseconds(header("last-modified", in: response.headers)) ?? 0,
            checkedAt: checkedAt,
            etag: header("etag", in: response.headers)
        )
        if context.signal.isCancelled { return }
        let published = remoteModels(entry)
        _ = await context.publish(ModelsPublication(persist: .write(entry), update: {
            updateOverlay(published)
        }))
    }

    public func mergeModels(baseline: [Model], dynamic: [Model]) -> [Model] {
        var merged = baseline
        for model in dynamic {
            if let index = merged.firstIndex(where: { $0.id == model.id }) {
                merged[index] = model
            } else {
                merged.append(model)
            }
        }
        return merged
    }

    private func remoteModels(_ entry: ModelsStoreEntry?) -> [Model] {
        guard let entry else { return [] }
        if let localGeneratedAt,
           entry.lastModified == nil || (entry.lastModified ?? 0) <= localGeneratedAt {
            return []
        }
        return entry.models
    }

    private func parseCatalog(_ data: Data) throws -> [Model] {
        let value = try JSONSerialization.jsonObject(with: data)
        let entries: [Any]
        if let array = value as? [Any] {
            entries = array
        } else if let object = value as? [String: Any], let models = object["models"] as? [Any] {
            entries = models
        } else if let object = value as? [String: Any] {
            entries = Array(object.values)
        } else {
            throw RemoteCatalogError.invalidCatalog(providerId)
        }

        let decoder = JSONDecoder()
        return try entries.compactMap { value in
            guard var object = value as? [String: Any], object["id"] != nil else { return nil }
            object["provider"] = providerId
            let data = try JSONSerialization.data(withJSONObject: object)
            return try decoder.decode(Model.self, from: data)
        }
    }
}

private func header(_ name: String, in headers: [String: String]) -> String? {
    headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
}

private func parseHTTPDateMilliseconds(_ value: String?) -> Double? {
    guard let value else { return nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
    return formatter.date(from: value).map { $0.timeIntervalSince1970 * 1_000 }
}

private func piUserAgent(version: String) -> String {
    #if os(macOS)
    let platform = "darwin"
    #elseif os(iOS)
    let platform = "ios"
    #else
    let platform = "swift"
    #endif
    #if arch(arm64)
    let architecture = "arm64"
    #elseif arch(x86_64)
    let architecture = "x64"
    #else
    let architecture = "unknown"
    #endif
    return "pi/\(version) (\(platform); swift; \(architecture))"
}
