/// A batch was rejected before any durable effect. The owning Session can continue.
public struct StorageRejected: Error, Sendable, Equatable, CustomStringConvertible {
    /// Text that describes the error, diagnostic, or model response.
    public let message: String
    /// Stores a rejection message for a batch with no durable effect.
    public init(_ message: String) { self.message = message }
    /// Text that describes this value or error to the caller.
    public var description: String { message }
}

/// Storage contract failures. Descriptions use the upstream backend error text.
public enum DurableStorageError: Error, Sendable, Equatable, CustomStringConvertible {
    /// the supplied value is closed.
    case closed(backend: String)
    /// ID space is exhausted.
    case idSpaceExhausted
    /// Invalid storage cursor.
    case invalidCursor
    /// Invalid scan order: the supplied value.
    case invalidScanOrder(String)
    /// The cursor continues a the supplied value scan; the query asks for the supplied value.
    case cursorOrderMismatch(stored: ScanOrder, requested: ScanOrder)
    /// Commit sequence the supplied value does not strictly increase.
    case commitSequenceDoesNotIncrease(Int64)
    /// Unknown conversation: the supplied value.
    case unknownConversation(ConversationID)
    /// Storage.entry() requires an entry ID.
    case entryIDRequired
    /// ID the supplied value already belongs to the supplied value.
    case idAlreadyOwned(id: Int64, recordType: String)
    /// ID the supplied value is written more than once.
    case idWrittenMoreThanOnce(Int64)
    /// ID the supplied value is written as two record types.
    case idWrittenAsTwoRecordTypes(Int64)
    /// Unknown document: the supplied value.
    case unknownDocument(DocumentID)
    /// Document the supplied value already exists.
    case documentAlreadyExists(DocumentID)
    /// Document the supplied value is retired.
    case documentRetired(DocumentID)
    /// Document the supplied value is retired more than once.
    case documentRetiredMoreThanOnce(DocumentID)
    /// Document the supplied value has more than one content command.
    case documentMultipleContentCommands(DocumentID)
    /// Document the supplied value delta has no base.
    case documentDeltaHasNoBase(DocumentID)
    /// Document the supplied value version transition requires a base.
    case documentVersionTransitionRequiresBase(DocumentID)
    /// Document the supplied value crosses a stored version boundary without a base.
    case documentVersionBoundaryWithoutBase(DocumentID)
    /// Document the supplied value is missing a required base.
    case documentMissingBase(DocumentID)
    /// Document the supplied value does not retain historical content.
    case documentDoesNotRetainHistory(DocumentID)
    /// Document address already has a current incarnation.
    case documentAddressOccupied
    /// Fork source document the supplied value is changed in the copy batch.
    case forkSourceChangedInCopyBatch(DocumentID)
    /// Fork source document the supplied value cannot be read.
    case forkSourceCannotBeRead(DocumentID)
    /// Fork source document the supplied value does not match the copied record.
    case forkSourceDoesNotMatch(DocumentID)
    /// Prepared document copy was not resolved.
    case preparedDocumentCopyNotResolved

    /// Text that describes this value or error to the caller.
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
