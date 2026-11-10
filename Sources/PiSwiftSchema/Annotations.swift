// Ported from packages/schema/src/annotations.ts, pi-mono v1.5.2.
// Annotation checks are built only for schemas below unevaluatedProperties or unevaluatedItems.
import Foundation
import Synchronization

// annotations.ts:7-14
struct Annotations: Sendable {
    var props: Set<[UInt16]>?
    var allProps: Bool
    var items: Int
    var allItems: Bool
    var indexes: Set<Int>?
}

// annotations.ts:16-17
typealias AnnotatingCheck = @Sendable (SchemaValue, inout Annotations) -> Bool

// annotations.ts:19-22
func newAnnotations() -> Annotations {
    Annotations(props: nil, allProps: false, items: 0, allItems: false, indexes: nil)
}

// annotations.ts:24-30
private func merge(_ a: inout Annotations, _ b: Annotations) {
    if let props = b.props { for key in props { addProp(&a, key) } }
    a.allProps = a.allProps || b.allProps
    if b.items > a.items { a.items = b.items }
    a.allItems = a.allItems || b.allItems
    if let indexes = b.indexes { for index in indexes { addIndex(&a, index) } }
}

// annotations.ts:32-35
private func addProp(_ a: inout Annotations, _ key: [UInt16]) {
    if a.props == nil { a.props = [] }
    a.props?.insert(key)
}

// annotations.ts:37-40
private func addIndex(_ a: inout Annotations, _ index: Int) {
    if a.indexes == nil { a.indexes = [] }
    a.indexes?.insert(index)
}

// annotations.ts:42-43
let ANNOTATING_TRUE: AnnotatingCheck = { _, _ in true }
let ANNOTATING_FALSE: AnnotatingCheck = { _, _ in false }

// Swift's Sendable rule needs a synchronized, set-once slot for a recursive reference.
private final class AnnotatingCheckBox: Sendable {
    let check: AnnotatingCheck
    init(_ check: @escaping AnnotatingCheck) { self.check = check }
}

final class AnnotatingSlot: Sendable {
    private let stored = Mutex<AnnotatingCheckBox?>(nil)

    func install(_ check: @escaping AnnotatingCheck) {
        stored.withLock { $0 = AnnotatingCheckBox(check) }
    }

    func run(_ value: SchemaValue, _ annotations: inout Annotations) -> Bool {
        guard let box = stored.withLock({ $0 }) else { return false }
        return box.check(value, &annotations)
    }
}

// annotations.ts:45-48
func indirectAnnotating(_ slot: AnnotatingSlot) -> AnnotatingCheck {
    { value, annotations in slot.run(value, &annotations) }
}

// annotations.ts:50-53
func ignoreAnnotations(_ check: @escaping Check) -> AnnotatingCheck {
    { value, _ in check(value) }
}

// annotations.ts:55-58
func withFreshAnnotations(_ check: @escaping AnnotatingCheck) -> Check {
    { value in
        var annotations = newAnnotations()
        return check(value, &annotations)
    }
}

// annotations.ts:60-68
func scopedAnnotating(scope: DynamicScope, uri: String, check: @escaping AnnotatingCheck) -> AnnotatingCheck {
    { value, annotations in
        scope.push(uri)
        defer { scope.pop() }
        return check(value, &annotations)
    }
}

// annotations.ts:70-78
func isolateAnnotations(_ check: @escaping AnnotatingCheck) -> AnnotatingCheck {
    { value, annotations in
        var own = newAnnotations()
        guard check(value, &own) else { return false }
        merge(&annotations, own)
        return true
    }
}

// annotations.ts:80-87
func annotateAll(_ plain: @escaping Check, _ parts: [AnnotatingCheck]) -> AnnotatingCheck {
    { value, annotations in
        guard plain(value) else { return false }
        for part in parts where !part(value, &annotations) { return false }
        return true
    }
}

// annotations.ts:89-121
func annotateObject(
    _ props: [(String, Check)],
    _ patterns: [(NSRegularExpression, Check)],
    _ additional: Check?
) -> AnnotatingCheck {
    let declared = Set(props.map { Array($0.0.utf16) })
    return { value, annotations in
        guard case .object(let object) = value else { return true }
        var seen: [[UInt16]] = []
        for (key, check) in props {
            guard let item = object[key] else { continue }
            guard check(item) else { return false }
            seen.append(Array(key.utf16))
        }
        for (key, item) in object {
            let units = Array(key.utf16)
            var matched = declared.contains(units)
            for (regex, check) in patterns where regexTest(regex, key) {
                guard check(item) else { return false }
                matched = true
                seen.append(units)
            }
            if !matched, let additional {
                guard additional(item) else { return false }
                seen.append(units)
            }
        }
        for key in seen { addProp(&annotations, key) }
        return true
    }
}

// annotations.ts:123-152
func annotateArray(
    _ prefix: [Check],
    _ rest: Check?,
    _ contains: Check?,
    _ minContains: Double,
    _ maxContains: Double
) -> AnnotatingCheck {
    { value, annotations in
        guard case .array(let array) = value else { return true }
        let count = Swift.min(array.count, prefix.count)
        for index in 0..<count where !prefix[index](array[index]) { return false }
        if let rest {
            if prefix.count < array.count {
                for index in prefix.count..<array.count where !rest(array[index]) { return false }
            }
            annotations.allItems = true
        }
        if count > annotations.items { annotations.items = count }
        if let contains {
            var matches = 0
            for (index, item) in array.enumerated() where contains(item) {
                matches += 1
                addIndex(&annotations, index)
            }
            if Double(matches) < minContains || Double(matches) > maxContains { return false }
        }
        return true
    }
}

// annotations.ts:154-167
func annotateAny(_ branches: [AnnotatingCheck], _ exactlyOne: Bool) -> AnnotatingCheck {
    { value, annotations in
        var matches = 0
        for branch in branches {
            var own = newAnnotations()
            if branch(value, &own) {
                matches += 1
                merge(&annotations, own)
            }
        }
        return exactlyOne ? matches == 1 : matches > 0
    }
}

// annotations.ts:169-183
func annotateIf(
    _ condition: @escaping AnnotatingCheck,
    _ then: AnnotatingCheck?,
    _ otherwise: AnnotatingCheck?
) -> AnnotatingCheck {
    { value, annotations in
        var own = newAnnotations()
        if condition(value, &own) {
            merge(&annotations, own)
            return then?(value, &annotations) ?? true
        }
        return otherwise?(value, &annotations) ?? true
    }
}

// annotations.ts:185-188
func annotateDependent(_ key: String, _ check: @escaping AnnotatingCheck) -> AnnotatingCheck {
    { value, annotations in
        guard case .object(let object) = value, object[key] != nil else { return true }
        return check(value, &annotations)
    }
}

// annotations.ts:190-198
func unevaluatedProperties(_ check: @escaping Check) -> AnnotatingCheck {
    { value, annotations in
        guard case .object(let object) = value, !annotations.allProps else { return true }
        for (key, item) in object {
            if !(annotations.props?.contains(Array(key.utf16)) ?? false), !check(item) { return false }
        }
        annotations.allProps = true
        return true
    }
}

// annotations.ts:200-208
func unevaluatedItems(_ check: @escaping Check) -> AnnotatingCheck {
    { value, annotations in
        guard case .array(let array) = value, !annotations.allItems else { return true }
        if annotations.items < array.count {
            for index in annotations.items..<array.count {
                if !(annotations.indexes?.contains(index) ?? false), !check(array[index]) { return false }
            }
        }
        annotations.allItems = true
        return true
    }
}
