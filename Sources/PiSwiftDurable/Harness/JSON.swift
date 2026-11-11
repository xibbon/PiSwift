import PiSwiftChord

/// Assigns JSON leaf by leaf. Existing object order is kept for retained keys.
/// D4 can use the same walk to apply leaf operations to a Chord document draft.
public func assignJSON(target: inout JSONValue, value: JSONValue) {
    switch (target, value) {
    case (.object(var current), .object(let next)):
        for key in current.keys where next[key] == nil { current.removeValue(forKey: key) }
        for (key, child) in next {
            if var old = current[key] { assignJSON(target: &old, value: child); current[key] = old }
            else { current[key] = child }
        }
        target = .object(current)
    case (.array(var current), .array(let next)) where current.count <= next.count:
        for (index, child) in next.enumerated() {
            if index < current.count { assignJSON(target: &current[index], value: child) }
            else { current.append(child) }
        }
        target = .array(current)
    default: if target != value { target = value }
    }
}

/// Specifies the known changes for one JSON value.
public indirect enum AssignPlan: Sendable {
    case append(String)
    case keep
    case fields([Delta.PathSegment: AssignPlan])
}

/// Assigns a document member. A valid append plan avoids a full string comparison.
public func assignJSON(target: JSONDraft, key: String, value: JSONValue, plan: AssignPlan? = nil) throws {
    if case .keep? = plan { return }
    let append: ((String) throws -> Void)? = try target.kind == .object ? { try target.appendText(key, $0) } : nil
    try assignDraftJSON(current: target.get(key), child: target.child(key), value: value,
                        plan: plan, append: append,
                        replace: { try target.set(key, $0) })
}

/// Assigns an array member through its draft.
public func assignJSON(target: JSONDraft, key: Int, value: JSONValue, plan: AssignPlan? = nil) throws {
    if case .keep? = plan { return }
    let append: ((String) throws -> Void)? = try target.kind == .object ? { try target.appendText(String(key), $0) } : nil
    try assignDraftJSON(current: target.get(key), child: target.child(key), value: value,
                        plan: plan, append: append, replace: { try target.set(key, $0) })
}

private func assignDraftJSON(current: JSONValue?, child: JSONDraft?, value: JSONValue,
                             plan: AssignPlan?, append: ((String) throws -> Void)?,
                             replace: (JSONValue) throws -> Void) throws {
    let fields: [Delta.PathSegment: AssignPlan]
    if case .fields(let plans)? = plan { fields = plans } else { fields = [:] }
    switch (current, value) {
    case (.object(let old)?, .object(let next)):
        guard let child else { throw DocumentDefinitionError("Object draft is missing") }
        for key in old.keys where next[key] == nil { try child.remove(key) }
        for (key, item) in next { try assignJSON(target: child, key: key, value: item, plan: fields[.key(key)]) }
    case (.array(let old)?, .array(let next)) where old.count <= next.count:
        guard let child else { throw DocumentDefinitionError("Array draft is missing") }
        for (index, item) in next.enumerated() {
            if index < old.count { try assignJSON(target: child, key: index, value: item, plan: fields[.index(index)]) }
            else { try child.append(item) }
        }
    case (.string(let old)?, .string(let next)):
        if case .append(let text)? = plan, let append,
           old.utf16.count + text.utf16.count == next.utf16.count {
            try append(text)
        } else if current != value { try replace(value) }
    default:
        if current != value { try replace(value) }
    }
}
