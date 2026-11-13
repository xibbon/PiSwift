import PiSwiftChord
import PiSwiftDurable

/// Opens a JSONL session for a host that only displays stored state.
/// Both the storage and Harness use their independent read-only modes. The
/// result is a snapshot; close it and call this function again to refresh.
/// This function does not take the coding agent's exclusive session lock.
public func openDurableJsonlViewer(
    directory: String,
    options: HarnessOptions,
    context: ChordContext = .background
) async throws -> Harness {
    let storage = try await JsonlStorage.open(directory: directory,
        options: .init(readOnly: true), context: context)
    var viewerOptions = options
    viewerOptions.readOnly = true
    do {
        return try await Harness.open(storage: storage, options: viewerOptions, context: context)
    } catch {
        try? await storage.close(context: context)
        throw error
    }
}
