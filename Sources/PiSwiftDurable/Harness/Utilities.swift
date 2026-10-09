import PiSwiftChord

/// Returns every item in scan page order. The scan owns its cursor values.
public func scanAll<Item: Sendable & Equatable & Codable>(
    scan: @Sendable (Cursor?) async throws -> Page<Item, Cursor>
) async throws -> [Item] {
    var items: [Item] = []
    var cursor: Cursor?
    repeat {
        let page = try await scan(cursor)
        items.append(contentsOf: page.items)
        cursor = page.next
    } while cursor != nil
    return items
}

/// An operation used a harness after it closed.
public struct HarnessClosedError: Error, Sendable, CustomStringConvertible {
    /// Creates the error for use of a closed harness.
    public init() {}
    /// Text that describes this value or error to the caller.
    public var description: String { "Harness is closed" }
}
/// Creates the error returned by a closed harness.
public func closedError() -> HarnessClosedError { HarnessClosedError() }
