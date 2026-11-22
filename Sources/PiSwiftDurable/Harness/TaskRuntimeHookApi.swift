import PiSwiftChord

extension TaskRuntime {
    /// Hooks share this invocation's document reads, model service, and memos.
    public var hookApi: HookApi {
        HookApi(taskId: taskId, conversationId: conversationId, models: self.models,
                read: invocationDocumentReader(), memo: { name, candidate, context in
                    try await self.memo(name, value: candidate, context: context.withAbortSignal(self.signal))
                }, now: { try self.now() }, entries: { query, limit, cursor, context in
                    try await self.entries(query, limit: limit, cursor: cursor, context: context)
                }, entry: { id, context in
                    try await self.entry(id, context: context)
                })
    }
    private func invocationDocumentReader() -> HarnessDocumentReader {
        let reader = documentReader(session: scheduler.session, storage: scheduler.storage)
        return HarnessDocumentReader(snapshot: { kind, id, context in
            try await self.hookRead(context) { try await reader.snapshot(kind, id, $0) }
        }, snapshotAsOf: { kind, id, at, context in
            try await self.hookRead(context) { try await reader.snapshotAsOf(kind, id, at, $0) }
        }, typedRead: { definition, address, context in
            try await self.hookRead(context) { context in
                try await self.scheduler.session.currentSnapshot(definition, address: address, context: context)
            }
        }, typedHistoricalRead: { definition, address, at, context in
            try await self.hookRead(context) { context in
                try await self.scheduler.session.historicalSnapshot(definition, address: address, at: at, context: context)
            }
        })
    }
    private func hookRead<Value>(_ context: ChordContext,
                                 read: (ChordContext) async throws -> Value) async throws -> Value {
        try await withTaskCancellationContext(context.withAbortSignal(signal)) { context in
            try invocation.check(); try context.abortSignal?.throwIfAborted()
            let value = try await read(context)
            try invocation.check(); try context.abortSignal?.throwIfAborted()
            return value
        }
    }
}
