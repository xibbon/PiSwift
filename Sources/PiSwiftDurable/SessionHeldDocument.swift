import PiSwiftChord

/// v1.5.2 D7 session.ts:91-99. One cached incarnation awaiting Storage.
internal struct SessionHeldDocument: Sendable {
    let loaded: LoadedDocument
    let pending: PendingOps
    var base: Bool
    var deadline: Double
}
