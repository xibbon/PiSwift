import PiSwiftChord
import PiSwiftDurable
import Synchronization

// Direct storage tests still need a one-batch sequence. Production storage
// exposes only the batch commit API.
extension DurableStorage {
    func commitOne(_ writes: [StorageWrite], context: ChordContext) async throws -> Seq {
        let sequence = Mutex<Seq?>(nil)
        let result = try await commit([writes], receive: { _, value in sequence.withLock { $0 = value } }, context: context)
        if let refused = result.refused { throw refused }
        guard let value = sequence.withLock({ $0 }) else {
            throw DurableStorageError.commitSequenceDoesNotIncrease(0)
        }
        return value
    }
}
