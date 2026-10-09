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
