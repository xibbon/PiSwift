import Foundation
import Synchronization

public enum HarnessDefinitionError: Error, Sendable, Equatable, CustomStringConvertible {
    case duplicateTool(extensionName: String, name: String)
    case duplicateSection(extensionName: String, key: String)
    case invalidSectionKey(String)
    case reservedSectionKey(String)
    case renamedWrapper(target: String, name: String)
    case argumentsMustBeObject(String)
    public var description: String {
        switch self {
        case let .duplicateTool(extensionName, name): return "Extension \(extensionName) has two tools named \(name)"
        case let .duplicateSection(extensionName, key): return "Extension \(extensionName) has two sections with key \(key)"
        case let .invalidSectionKey(key): return "Section key \(key) must match /^[a-z][a-z0-9_-]*$/"
        case let .reservedSectionKey(key): return "Section key \(key) is reserved for the agent's instructions"
        case let .renamedWrapper(target, name): return "Wrapper renamed \(target) to \(name)"
        case let .argumentsMustBeObject(name): return "Arguments of tool \(name) must be an object"
        }
    }
}

public struct RegistrySnapshot: Sendable {
    private let extensions: [Extension]
    public init(extensions: [Extension] = []) { self.extensions = extensions }
    public func installed() -> [Extension] { extensions }
    public func `extension`(name: String) -> Extension? { extensions.first { harnessNamesEqual($0.name, name) } }
    public func tools() -> [(extension: Extension, tool: ToolRegistration)] {
        extensions.flatMap { item in item.tools.map { (item, $0) } }
    }
    public func sections() -> [(extension: Extension, section: PromptSection)] {
        extensions.flatMap { item in item.sections.map { (item, $0) } }
    }
    // H5 adds built-in and installed task lookup once task kinds are available.
}

public protocol RegistryReader: Sendable {
    func snapshot() -> RegistrySnapshot
    /// Synchronous publication notification. The returned closure removes this listener.
    func subscribe(_ listener: @escaping @Sendable () -> Void) -> @Sendable () -> Void
}
/// Application-owned registry. Values in prior snapshots do not change after publication.
public final class Registry: RegistryReader, Sendable {
    private struct State: Sendable {
        var current = RegistrySnapshot()
        var listeners: [(UUID, @Sendable () -> Void)] = []
    }
    private let state = Mutex(State())
    public init() {}
    public func snapshot() -> RegistrySnapshot { state.withLock { $0.current } }
    public func subscribe(_ listener: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        let id = UUID()
        state.withLock { $0.listeners.append((id, listener)) }
        return { [self] in state.withLock { $0.listeners.removeAll { $0.0 == id } } }
    }
    public func install(_ extensionValue: Extension) throws {
        try validateExtension(extensionValue)
        let callbacks = state.withLock { state in
            var installed = state.current.installed()
            if let index = installed.firstIndex(where: { harnessNamesEqual($0.name, extensionValue.name) }) { installed[index] = extensionValue }
            else { installed.append(extensionValue) }
            state.current = RegistrySnapshot(extensions: installed)
            return state.listeners.map(\.1)
        }
        for callback in callbacks { callback() }
    }
    public func uninstall(_ extensionValue: Extension) { uninstall(name: extensionValue.name) }
    public func uninstall(name: String) {
        let callbacks = state.withLock { state -> [@Sendable () -> Void] in
            let installed = state.current.installed()
            guard installed.contains(where: { harnessNamesEqual($0.name, name) }) else { return [] }
            state.current = RegistrySnapshot(extensions: installed.filter { !harnessNamesEqual($0.name, name) })
            return state.listeners.map(\.1)
        }
        for callback in callbacks { callback() }
    }
}
public func createRegistry() -> Registry { Registry() }

private func validateExtension(_ value: Extension) throws {
    var tools = Set<[UInt16]>()
    for tool in value.tools {
        guard tools.insert(Array(tool.name.utf16)).inserted else { throw HarnessDefinitionError.duplicateTool(extensionName: value.name, name: tool.name) }
    }
    var sections = Set<String>()
    for section in value.sections {
        let codes = Array(section.key.utf8)
        guard let first = codes.first, (97...122).contains(first), codes.dropFirst().allSatisfy({
            (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45
        }) else { throw HarnessDefinitionError.invalidSectionKey(section.key) }
        guard section.key != instructionsKey else { throw HarnessDefinitionError.reservedSectionKey(section.key) }
        guard sections.insert(section.key).inserted else { throw HarnessDefinitionError.duplicateSection(extensionName: value.name, key: section.key) }
    }
}
