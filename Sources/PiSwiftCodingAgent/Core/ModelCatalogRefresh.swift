import Foundation
import PiSwiftAI

public enum ModelsPersistAction: Sendable {
    case unchanged
    case write(ModelsStoreEntry)
    case delete
}

public struct ModelsPublication: Sendable {
    public var persist: ModelsPersistAction
    public var update: (@Sendable () -> Void)?

    public init(
        persist: ModelsPersistAction = .unchanged,
        update: (@Sendable () -> Void)? = nil
    ) {
        self.persist = persist
        self.update = update
    }
}

public struct RefreshModelsContext: Sendable {
    public let credential: String?
    /// Immutable snapshot captured before this refresh phase.
    public let stored: ModelsStoreEntry?
    public let allowNetwork: Bool
    public let force: Bool
    /// Always present, including when the caller did not supply a token.
    public let signal: CancellationToken
    /// Generation-checked publication transaction.
    public let publish: @Sendable (ModelsPublication) async -> Bool

    public init(
        credential: String?,
        stored: ModelsStoreEntry?,
        allowNetwork: Bool,
        force: Bool,
        signal: CancellationToken,
        publish: @escaping @Sendable (ModelsPublication) async -> Bool
    ) {
        self.credential = credential
        self.stored = stored
        self.allowNetwork = allowNetwork
        self.force = force
        self.signal = signal
        self.publish = publish
    }
}

public struct ModelsRefreshOptions: Sendable {
    public var allowNetwork: Bool
    public var providers: [String]?
    public var force: Bool
    public var signal: CancellationToken?

    public init(
        allowNetwork: Bool = true,
        providers: [String]? = nil,
        force: Bool = false,
        signal: CancellationToken? = nil
    ) {
        self.allowNetwork = allowNetwork
        self.providers = providers
        self.force = force
        self.signal = signal
    }
}

public struct ModelsRefreshResult: Sendable {
    public var aborted: Bool
    public var errors: [String: any Error]

    public init(aborted: Bool, errors: [String: any Error] = [:]) {
        self.aborted = aborted
        self.errors = errors
    }
}

public struct ModelsRefreshSource: Sendable {
    public let id: String
    public let readStoredCredential: @Sendable () async throws -> String?
    public let resolveCredential: @Sendable (CancellationToken) async throws -> String?
    public let refresh: @Sendable (RefreshModelsContext) async throws -> Void

    public init(
        id: String,
        readStoredCredential: @escaping @Sendable () async throws -> String?,
        resolveCredential: @escaping @Sendable (CancellationToken) async throws -> String?,
        refresh: @escaping @Sendable (RefreshModelsContext) async throws -> Void
    ) {
        self.id = id
        self.readStoredCredential = readStoredCredential
        self.resolveCredential = resolveCredential
        self.refresh = refresh
    }
}

private struct ProviderRefreshState: Sendable {
    var generation = 0
    var signal: CancellationToken?
}

private struct ProviderRefreshOutcome: Sendable {
    var providerId: String
    var error: (any Error)?
}

/// Coordinates model restore and network refresh phases for all dynamic providers.
public actor ModelCatalogRefreshCoordinator {
    private let store: any ModelsStore
    private let sources: [String: ModelsRefreshSource]
    private var refreshStates: [String: ProviderRefreshState] = [:]

    public init(store: any ModelsStore, sources: [ModelsRefreshSource]) {
        self.store = store
        self.sources = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
    }

    public func refresh(_ options: ModelsRefreshOptions = .init()) async -> ModelsRefreshResult {
        let operationSignal = CancellationToken()
        if options.signal?.isCancelled == true || Task.isCancelled {
            operationSignal.cancel()
            return ModelsRefreshResult(aborted: true)
        }

        let callerMonitor = makeCancellationMonitor(parent: options.signal, child: operationSignal)
        defer { callerMonitor?.cancel() }
        let selected = options.providers.map(Set.init)
        let refreshable = sources.values
            .filter { selected == nil || selected?.contains($0.id) == true }
            .sorted { $0.id < $1.id }
        let runs = refreshable.map { source in
            let (generation, signal) = beginRefresh(providerId: source.id)
            return (source: source, generation: generation, signal: signal)
        }

        let outcomes = await withTaskCancellationHandler {
            await withTaskGroup(of: ProviderRefreshOutcome.self, returning: [ProviderRefreshOutcome].self) { group in
                for run in runs {
                    group.addTask {
                        await self.refresh(
                            source: run.source,
                            generation: run.generation,
                            providerSignal: run.signal,
                            options: options,
                            operationSignal: operationSignal
                        )
                    }
                }
                var values: [ProviderRefreshOutcome] = []
                for await outcome in group {
                    values.append(outcome)
                }
                return values
            }
        } onCancel: {
            operationSignal.cancel()
        }

        var errors: [String: any Error] = [:]
        for outcome in outcomes {
            if let error = outcome.error {
                errors[outcome.providerId] = error
            }
        }
        return ModelsRefreshResult(aborted: operationSignal.isCancelled, errors: errors)
    }

    private func refresh(
        source: ModelsRefreshSource,
        generation: Int,
        providerSignal: CancellationToken,
        options: ModelsRefreshOptions,
        operationSignal: CancellationToken
    ) async -> ProviderRefreshOutcome {
        let operationMonitor = makeCancellationMonitor(parent: operationSignal, child: providerSignal)
        defer {
            operationMonitor?.cancel()
            finishRefresh(providerId: source.id, generation: generation, signal: providerSignal)
        }

        do {
            var storedCredential: String?
            var credentialError: (any Error)?
            do {
                storedCredential = try await source.readStoredCredential()
            } catch {
                credentialError = error
            }

            try await runPhase(
                source: source,
                credential: storedCredential,
                allowNetwork: false,
                force: false,
                generation: generation,
                signal: providerSignal
            )
            if let credentialError { throw credentialError }
            guard options.allowNetwork, !providerSignal.isCancelled else {
                return ProviderRefreshOutcome(providerId: source.id)
            }

            guard let credential = try await source.resolveCredential(providerSignal),
                  !providerSignal.isCancelled else {
                return ProviderRefreshOutcome(providerId: source.id)
            }
            try await runPhase(
                source: source,
                credential: credential,
                allowNetwork: true,
                force: options.force,
                generation: generation,
                signal: providerSignal
            )
            return ProviderRefreshOutcome(providerId: source.id)
        } catch {
            if providerSignal.isCancelled || operationSignal.isCancelled {
                return ProviderRefreshOutcome(providerId: source.id)
            }
            return ProviderRefreshOutcome(providerId: source.id, error: error)
        }
    }

    private func runPhase(
        source: ModelsRefreshSource,
        credential: String?,
        allowNetwork: Bool,
        force: Bool,
        generation: Int,
        signal: CancellationToken
    ) async throws {
        if signal.isCancelled { throw OAuthError.cancelled }
        let stored = try await store.read(providerId: source.id, signal: signal)
        let publicationError = LockedState<(any Error)?>(nil)
        let context = RefreshModelsContext(
            credential: credential,
            stored: stored,
            allowNetwork: allowNetwork,
            force: force,
            signal: signal,
            publish: { [weak self] publication in
                guard let self else { return false }
                do {
                    return try await self.publish(
                        providerId: source.id,
                        generation: generation,
                        signal: signal,
                        publication: publication
                    )
                } catch {
                    publicationError.withLock { $0 = error }
                    return false
                }
            }
        )
        try await source.refresh(context)
        if let error = publicationError.withLock({ $0 }) {
            throw error
        }
    }

    private func beginRefresh(providerId: String) -> (Int, CancellationToken) {
        var state = refreshStates[providerId] ?? ProviderRefreshState()
        state.generation += 1
        state.signal?.cancel()
        let signal = CancellationToken()
        state.signal = signal
        refreshStates[providerId] = state
        return (state.generation, signal)
    }

    private func finishRefresh(providerId: String, generation: Int, signal: CancellationToken) {
        guard let state = refreshStates[providerId],
              state.generation == generation,
              state.signal === signal else { return }
        refreshStates[providerId]?.signal = nil
    }

    private func publish(
        providerId: String,
        generation: Int,
        signal: CancellationToken,
        publication: ModelsPublication
    ) async throws -> Bool {
        guard isCurrent(providerId: providerId, generation: generation, signal: signal) else {
            return false
        }

        switch publication.persist {
        case .unchanged:
            break
        case .write(let entry):
            try await store.write(providerId: providerId, entry: entry, signal: signal)
        case .delete:
            try await store.delete(providerId: providerId, signal: signal)
        }

        guard isCurrent(providerId: providerId, generation: generation, signal: signal) else {
            return false
        }
        publication.update?()
        return true
    }

    private func isCurrent(providerId: String, generation: Int, signal: CancellationToken) -> Bool {
        guard !signal.isCancelled,
              let state = refreshStates[providerId] else { return false }
        return state.generation == generation && state.signal === signal
    }
}

private func makeCancellationMonitor(
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
