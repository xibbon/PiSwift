import PiSwiftChord

/// One stored document selected for a conversation fork.
internal struct ForkDocumentCopy: Sendable {
    let record: DocumentCreate
    let source: DocumentCopySource
    var address: DocumentAddress { DocumentAddress(kind: record.kind, scope: record.scope, key: record.key) }
}

/// Select stored records. Storage resolves their content before it applies the batch.
internal func prepareForkDocumentCopies(storage: any DurableStorage, parentConversationId: ConversationID,
                                       at: EntryID, childConversationId: ConversationID,
                                       context: PiSwiftChord.Context) async throws -> [ForkDocumentCopy] {
    guard let entry = try await storage.entry(parentConversationId, id: at, context: context) else {
        throw SessionError.message("Entry \(at.rawValue) is not visible from conversation \(parentConversationId.rawValue)")
    }
    var copies: [ForkDocumentCopy] = []
    var addresses: Set<[UInt8]> = []
    try await collectForkCopies(storage: storage, scope: .conversation(conversationId: entry.entry.conversationId),
                                at: .sequence(entry.commitSeq), policy: .asOf, child: childConversationId,
                                copies: &copies, addresses: &addresses, context: context)
    try await collectForkCopies(storage: storage, scope: .conversation(conversationId: parentConversationId),
                                at: .current, policy: .current, child: childConversationId,
                                copies: &copies, addresses: &addresses, context: context)
    return copies
}

private func collectForkCopies(storage: any DurableStorage, scope: DocumentScope, at: DocumentPoint,
                               policy: DocumentFork, child: ConversationID, copies: inout [ForkDocumentCopy],
                               addresses: inout Set<[UInt8]>, context: PiSwiftChord.Context) async throws {
    var cursor: Cursor?
    repeat {
        let page = try await storage.scanDocuments(DocumentQuery(scope: scope, at: at), limit: 256, cursor: cursor, context: context)
        for source in page.items {
            guard case .conversation = source.scope, source.fork == policy else { continue }
            let id: DocumentID = try await storage.mintId()
            let record = DocumentCreate(id: id, kind: source.kind, scope: .conversation(conversationId: child),
                                        key: source.key, history: source.history, fork: source.fork)
            let address = DocumentAddress(kind: record.kind, scope: record.scope, key: record.key)
            guard addresses.insert(Array(documentAddressID(address).utf8)).inserted else {
                let member = source.key.map { "\(source.kind)/\($0)" } ?? source.kind
                throw SessionError.message("Fork selects multiple source documents for \(member)")
            }
            copies.append(ForkDocumentCopy(record: record, source: DocumentCopySource(id: source.id, at: at)))
        }
        cursor = page.next
    } while cursor != nil
}
