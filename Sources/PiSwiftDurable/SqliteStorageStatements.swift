import PiSwiftChord

/// Splits JSON parameters at the tagged backend's 512 Ki UTF-16 character limit.
func sqliteJSONArrayChunks(_ values: [JSONValue]) throws -> [String] {
    var chunks: [String] = [], parts: [String] = []
    var length = 2
    for value in values {
        let part = try value.jsonText()
        if !parts.isEmpty, length + 1 + part.utf16.count > 512 * 1024 {
            chunks.append("[" + parts.joined(separator: ",") + "]")
            parts = []; length = 2
        }
        length += (parts.isEmpty ? 0 : 1) + part.utf16.count
        parts.append(part)
    }
    if !parts.isEmpty { chunks.append("[" + parts.joined(separator: ",") + "]") }
    return chunks
}
func sqliteCellJSON(_ value: SqliteValue) -> JSONValue {
    switch value {
    case .null: .null
    case .integer(let value): .number(Double(value))
    case .real(let value): .number(value)
    case .text(let value): .string(value)
    case .blob: preconditionFailure("Durable rows do not contain blobs")
    }
}
func sqliteReadRows(_ executor: any SqliteExecutor, sql: String, values: [JSONValue]) throws -> [SqliteRow] {
    try sqliteJSONArrayChunks(values).flatMap { try executor.all(sql, [.text($0)]) }
}
func sqliteRunForEach(_ executor: any SqliteExecutor, sql: String, values: [JSONValue]) throws {
    for chunk in try sqliteJSONArrayChunks(values) { try executor.run(sql, [.text(chunk)]) }
}
/// Uses one JSON parameter for small rows and bound columns for rows with large text.
func sqliteInsertRows(_ executor: any SqliteExecutor, table: String, columns: [String], rows: [[SqliteValue]], conflict: String = "") throws {
    var small: [JSONValue] = [], large: [[SqliteValue]] = []
    for row in rows {
        let characters = row.reduce(0) { result, cell in
            if case .text(let text) = cell { return result + text.utf16.count }
            return result
        }
        if characters > 8 * 1024 { large.append(row) }
        else { small.append(.array(row.map(sqliteCellJSON))) }
    }
    let names = columns.joined(separator: ", ")
    if !small.isEmpty {
        let cells = columns.indices.map { "json_extract(item.value, '$[\($0)]')" }.joined(separator: ", ")
        let sql = "INSERT INTO \(table) (\(names)) SELECT \(cells) FROM json_each(?) AS item WHERE true \(conflict)"
        try sqliteRunForEach(executor, sql: sql, values: small)
    }
    let row = "(" + Array(repeating: "?", count: columns.count).joined(separator: ", ") + ")"
    var size = 1
    while size * 2 * columns.count <= 100 { size *= 2 }
    var start = 0
    while start < large.count {
        while size > large.count - start { size /= 2 }
        let sql = "INSERT INTO \(table) (\(names)) VALUES " + Array(repeating: row, count: size).joined(separator: ", ") + " " + conflict
        try executor.run(sql, large[start..<(start + size)].flatMap { $0 })
        start += size
    }
}
