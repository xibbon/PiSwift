/// Keys used by the Session writer. These are exact identities, apart from `allKeys`.
/// v1.5.2 session/keys.ts:36–114.
internal enum SessionKeys {
    static func taskKey(_ id: TaskID) -> String { "task:\(id.rawValue)" }
    static func conversationKey(_ id: ConversationID) -> String { "conv:\(id.rawValue)" }
    static func entryKey(_ id: EntryID) -> String { "entry:\(id.rawValue)" }
    static func appendKey(_ id: ConversationID) -> String { "entry-append:\(id.rawValue)" }
    static func submissionKey(_ id: SubmissionID) -> String { "sub:\(id.rawValue)" }
    static func requestKey(_ id: ConversationID, _ requestID: String) -> String {
        "req:\(id.rawValue):\(requestID)"
    }
    static func documentKey(_ addressID: String) -> String { "doc:\(addressID)" }
    static func documentKey(_ address: DocumentAddress) -> String { documentKey(documentAddressID(address)) }
    static func incarnationKey(_ id: DocumentID) -> String { "docid:\(id.rawValue)" }
    static func scopeKey(_ scope: DocumentScope) -> String {
        switch scope {
        case .session: "docscope:session"
        case .conversation(let id, _): "docscope:c\(id.rawValue)"
        case .task(let id, _): "docscope:t\(id.rawValue)"
        }
    }
    static func ownedKey(_ node: String) -> String { "owned:\(node)" }
    static let rootsKey = "roots"
    static let intentKey = "intent"
    static let allKeys = "*"

    /// v1.5.2 session/keys.ts:116–138 `tableKeys`.
    static func tableKeys(_ writes: [StorageWrite], into keys: inout [String]) {
        for write in writes {
            switch write {
            case .conversation(let value, _): keys.append(conversationKey(value.id))
            case .entry(let value, _):
                keys.append(entryKey(value.id))
                keys.append(appendKey(value.conversationId))
            case .task(let value, _): keys.append(taskKey(value.id))
            case .submission(let value, _):
                keys.append(submissionKey(value.id))
                if let requestID = value.requestId {
                    keys.append(requestKey(value.conversationId, requestID))
                }
            default: break
            }
        }
    }
}
