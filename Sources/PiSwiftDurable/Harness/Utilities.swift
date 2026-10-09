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

public struct HarnessClosedError: Error, Sendable, CustomStringConvertible {
    public init() {}
    public var description: String { "Harness is closed" }
}
public func closedError() -> HarnessClosedError { HarnessClosedError() }
