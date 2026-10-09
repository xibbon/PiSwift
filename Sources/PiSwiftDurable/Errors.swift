/// A batch was rejected before any durable effect. The owning Session can continue.
public struct StorageRejected: Error, Sendable, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Storage contract failures. Descriptions use the upstream backend error text.
public enum DurableStorageError: Error, Sendable, Equatable, CustomStringConvertible {
    case closed(backend: String)
    case idSpaceExhausted
    case invalidCursor
    case invalidScanOrder(String)
    case cursorOrderMismatch(stored: ScanOrder, requested: ScanOrder)
    case commitSequenceDoesNotIncrease(Int64)
    case unknownConversation(ConversationID)
    case entryIDRequired
    case idAlreadyOwned(id: Int64, recordType: String)
    case idWrittenMoreThanOnce(Int64)
    case idWrittenAsTwoRecordTypes(Int64)
    case unknownDocument(DocumentID)
    case documentAlreadyExists(DocumentID)
    case documentRetired(DocumentID)
    case documentRetiredMoreThanOnce(DocumentID)
    case documentMultipleContentCommands(DocumentID)
    case documentDeltaHasNoBase(DocumentID)
    case documentVersionTransitionRequiresBase(DocumentID)
    case documentVersionBoundaryWithoutBase(DocumentID)
    case documentMissingBase(DocumentID)
    case documentDoesNotRetainHistory(DocumentID)
    case documentAddressOccupied
    case forkSourceChangedInCopyBatch(DocumentID)
    case forkSourceCannotBeRead(DocumentID)
    case forkSourceDoesNotMatch(DocumentID)
    case preparedDocumentCopyNotResolved

    public var description: String {
        switch self {
        case .closed(let backend): "\(backend) is closed"
        case .idSpaceExhausted: "ID space is exhausted"
        case .invalidCursor: "Invalid storage cursor"
        case .invalidScanOrder(let order): "Invalid scan order: \(order)"
        case .cursorOrderMismatch(let stored, let requested): "The cursor continues a \(stored.rawValue) scan; the query asks for \(requested.rawValue)"
        case .commitSequenceDoesNotIncrease(let seq): "Commit sequence \(seq) does not strictly increase"
        case .unknownConversation(let id): "Unknown conversation: \(id.rawValue)"
        case .entryIDRequired: "Storage.entry() requires an entry ID"
        case .idAlreadyOwned(let id, let type): "ID \(id) already belongs to \(type)"
        case .idWrittenMoreThanOnce(let id): "ID \(id) is written more than once"
        case .idWrittenAsTwoRecordTypes(let id): "ID \(id) is written as two record types"
        case .unknownDocument(let id): "Unknown document: \(id.rawValue)"
        case .documentAlreadyExists(let id): "Document \(id.rawValue) already exists"
        case .documentRetired(let id): "Document \(id.rawValue) is retired"
        case .documentRetiredMoreThanOnce(let id): "Document \(id.rawValue) is retired more than once"
        case .documentMultipleContentCommands(let id): "Document \(id.rawValue) has more than one content command"
        case .documentDeltaHasNoBase(let id): "Document \(id.rawValue) delta has no base"
        case .documentVersionTransitionRequiresBase(let id): "Document \(id.rawValue) version transition requires a base"
        case .documentVersionBoundaryWithoutBase(let id): "Document \(id.rawValue) crosses a stored version boundary without a base"
        case .documentMissingBase(let id): "Document \(id.rawValue) is missing a required base"
        case .documentDoesNotRetainHistory(let id): "Document \(id.rawValue) does not retain historical content"
        case .documentAddressOccupied: "Document address already has a current incarnation"
        case .forkSourceChangedInCopyBatch(let id): "Fork source document \(id.rawValue) is changed in the copy batch"
        case .forkSourceCannotBeRead(let id): "Fork source document \(id.rawValue) cannot be read"
        case .forkSourceDoesNotMatch(let id): "Fork source document \(id.rawValue) does not match the copied record"
        case .preparedDocumentCopyNotResolved: "Prepared document copy was not resolved"
        }
    }
}
