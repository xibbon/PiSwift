import PiSwiftChord

/// Options for a bounded tree listing.
public struct ListFilesOptions: Sendable {
    /// Include dot names (and Windows hidden entries). Nil means true. Never include entries named `.git`.
    public var hidden: Bool?
    /// Apply git ignore rules in work trees. Nil means true. Outside work trees, ignore files have no effect.
    /// Include parent and child `.gitignore`, `.git/info/exclude`, and global rules, even for tracked files.
    public var gitignore: Bool?
    /// Entry names to omit, with all their children.
    public var exclude: [String]?
    /// The entry limit. Nil means 50,000. Must be a non-negative safe integer.
    public var maxEntries: Double?
    /// The byte limit. Nil means 4 MiB. Values above 16 MiB minus 64 KiB are clamped to that cap.
    /// Each entry uses its UTF-8 path byte count plus two. Must be a non-negative safe integer.
    public var maxBytes: Double?
    /// The time limit in milliseconds. Nil means 10,000. Must be a non-negative safe integer.
    public var timeoutMs: Double?
    /// Creates listing options. Numeric fields use Double to permit validation of noninteger input.
    public init(hidden: Bool? = nil, gitignore: Bool? = nil, exclude: [String]? = nil,
                maxEntries: Double? = nil, maxBytes: Double? = nil, timeoutMs: Double? = nil) {
        self.hidden = hidden; self.gitignore = gitignore; self.exclude = exclude
        self.maxEntries = maxEntries; self.maxBytes = maxBytes; self.timeoutMs = timeoutMs
    }
}

/// One entry of a tree listing.
public struct FileListEntry: Sendable, Equatable {
    /// The path relative to the listed directory, with `/` separators on all systems.
    public var path: String
    /// The entry kind. A symbolic link is listed without following its children.
    public var kind: FileKind
    /// Creates a listing entry.
    public init(path: String, kind: FileKind) { self.path = path; self.kind = kind }
}

/// A bounded tree listing, in depth-first order, with parents before their children.
public struct FileListing: Sendable, Equatable {
    /// The entries. Sibling names are in byte order.
    public var entries: [FileListEntry]
    /// Whether an option bound stopped the listing early.
    public var truncated: Bool
    /// Creates a tree listing.
    public init(entries: [FileListEntry], truncated: Bool) { self.entries = entries; self.truncated = truncated }
}

/// Validated listing bounds, with defaults and the byte cap applied.
public struct ListFilesBounds: Sendable, Equatable {
    /// The maximum number of entries.
    public let maxEntries: Int
    /// The maximum number of encoded path bytes, including two bytes per entry.
    public let maxBytes: Int
    /// The maximum time in milliseconds.
    public let timeoutMs: Int
}

/// Checks bounds in upstream order. Zero is valid. Safe integers are at most 9,007,199,254,740,991.
/// Implementations can use this check before cancellation and file access.
public func listFilesBounds(options: ListFilesOptions? = nil, path: String? = nil) -> Result<ListFilesBounds, FileError> {
    let values: [(String, Double?)] = [
        ("maxEntries", options?.maxEntries), ("maxBytes", options?.maxBytes), ("timeoutMs", options?.timeoutMs),
    ]
    for (key, value) in values {
        if let value, !value.isFinite || value < 0 || value.rounded(.towardZero) != value || value > 9_007_199_254_740_991 {
            return .failure(FileError(.invalid, message: "\(key) must be a non-negative safe integer", path: path))
        }
    }
    let maxEntries = Int(options?.maxEntries ?? 50_000)
    let requestedBytes = options?.maxBytes ?? 4_194_304
    let maxBytes = Int(min(requestedBytes, 16_711_680))
    let timeoutMs = Int(options?.timeoutMs ?? 10_000)
    return .success(ListFilesBounds(maxEntries: maxEntries, maxBytes: maxBytes, timeoutMs: timeoutMs))
}

public extension FileSystem {
    /// Returns notSupported until an environment supplies this optional capability.
    func listFiles(_ path: String, options: ListFilesOptions?, context: ChordContext) async -> Result<FileListing, FileError> {
        .failure(FileError(.notSupported, message: "This environment does not list files", path: path))
    }
}
