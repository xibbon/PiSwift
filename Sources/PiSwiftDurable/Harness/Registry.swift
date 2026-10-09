import Foundation
import Synchronization

/// An extension or tool definition violates a registry constraint.
public enum HarnessDefinitionError: Error, Sendable, Equatable, CustomStringConvertible {
    /// An extension contains two tools with the same name.
    case duplicateTool(extensionName: String, name: String)
    /// An extension contains two prompt sections with the same key.
    case duplicateSection(extensionName: String, key: String)
    /// The section key does not use the permitted lowercase name format.
    case invalidSectionKey(String)
    /// The section key is reserved for agent instructions.
    case reservedSectionKey(String)
    /// A tool wrapper changed the name of its target tool.
    case renamedWrapper(target: String, name: String)
    /// The tool arguments must be a JSON object.
    case argumentsMustBeObject(String)
    /// Two installed definitions use the same task name.
    case duplicateTask(extensionName: String, name: String)
    /// Text that describes this value or error to the caller.
    public var description: String {
        switch self {
        case let .duplicateTool(extensionName, name): return "Extension \(extensionName) has two tools named \(name)"
        case let .duplicateSection(extensionName, key): return "Extension \(extensionName) has two sections with key \(key)"
        case let .invalidSectionKey(key): return "Section key \(key) must match /^[a-z][a-z0-9_-]*$/"
        case let .reservedSectionKey(key): return "Section key \(key) is reserved for the agent's instructions"
        case let .renamedWrapper(target, name): return "Wrapper renamed \(target) to \(name)"
        case let .argumentsMustBeObject(name): return "Arguments of tool \(name) must be an object"
        case let .duplicateTask(extensionName, name): return "Task \(name) of extension \(extensionName) is already installed"
        }
    }
}

/// An immutable view of installed extensions and built-in task definitions.
public struct RegistrySnapshot: Sendable {
    private let extensions: [Extension]
    private let builtins: [AnyTaskDefinition]
    /// Creates a snapshot of extensions with the built-in task definitions.
    public init(extensions: [Extension] = []) {
        self.extensions = extensions; builtins = AnyTaskDefinition.builtins
    }
    internal init(extensions: [Extension], builtins: [AnyTaskDefinition]) {
        self.extensions = extensions; self.builtins = builtins
    }
    /// Returns installed extensions in registration order.
    public func installed() -> [Extension] { extensions }
    /// Returns the installed extension with this name, or nil when absent.
    public func `extension`(name: String) -> Extension? { extensions.first { harnessNamesEqual($0.name, name) } }
    /// Returns installed tool registrations with their owning extensions.
    public func tools() -> [(extension: Extension, tool: ToolRegistration)] {
        extensions.flatMap { item in item.tools.map { (item, $0) } }
    }
    /// Returns selected extension sections in their installed order.
    public func sections() -> [(extension: Extension, section: PromptSection)] {
        extensions.flatMap { item in item.sections.map { (item, $0) } }
    }
    /// Returns built-in and installed task definitions in registry order.
    public func tasks() -> [AnyTaskDefinition] { builtins + extensions.flatMap(\.tasks) }
    /// Returns the installed task definition with this stable name, or nil when absent.
    public func task(name: String) -> AnyTaskDefinition? { tasks().first { harnessNamesEqual($0.name, name) } }
}

/// Supplies immutable registry snapshots and installation notifications.
public protocol RegistryReader: Sendable {
    /// Returns the current immutable registry snapshot.
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
    private let builtins: [AnyTaskDefinition]
    /// Creates an empty application registry with the built-in task definitions.
    public init() { builtins = AnyTaskDefinition.builtins }
    internal init(builtins: [AnyTaskDefinition]) {
        self.builtins = builtins
        state.withLock { $0.current = RegistrySnapshot(extensions: [], builtins: builtins) }
    }
    /// Returns the current immutable registry snapshot.
    public func snapshot() -> RegistrySnapshot { state.withLock { $0.current } }
    /// Adds a synchronous registry-publication listener and returns a closure that removes it.
    public func subscribe(_ listener: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        let id = UUID()
        state.withLock { $0.listeners.append((id, listener)) }
        return { [self] in state.withLock { $0.listeners.removeAll { $0.0 == id } } }
    }
    /// Validates and publishes an extension. An equal name replaces the previous extension.
    public func install(_ extensionValue: Extension) throws {
        try validateExtension(extensionValue)
        let callbacks = try state.withLock { state in
            var installed = state.current.installed()
            if let index = installed.firstIndex(where: { harnessNamesEqual($0.name, extensionValue.name) }) { installed[index] = extensionValue }
            else { installed.append(extensionValue) }
            try validateTasks(installed)
            state.current = RegistrySnapshot(extensions: installed, builtins: builtins)
            return state.listeners.map(\.1)
        }
        for callback in callbacks { callback() }
    }
    /// Removes the extension by name and publishes a new registry snapshot.
    public func uninstall(_ extensionValue: Extension) { uninstall(name: extensionValue.name) }
    /// Removes the extension by name and publishes a new registry snapshot.
    public func uninstall(name: String) {
        let callbacks = state.withLock { state -> [@Sendable () -> Void] in
            let installed = state.current.installed()
            guard installed.contains(where: { harnessNamesEqual($0.name, name) }) else { return [] }
            state.current = RegistrySnapshot(extensions: installed.filter { !harnessNamesEqual($0.name, name) }, builtins: builtins)
            return state.listeners.map(\.1)
        }
        for callback in callbacks { callback() }
    }
}
/// Creates an empty application registry with the built-in task definitions.
public func createRegistry() -> Registry {
    Registry()
}

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

private func validateTasks(_ extensions: [Extension]) throws {
    var names = Set(AnyTaskDefinition.builtins.map { Array($0.name.utf16) })
    for item in extensions {
        for task in item.tasks {
            guard names.insert(Array(task.name.utf16)).inserted else {
                throw HarnessDefinitionError.duplicateTask(extensionName: item.name, name: task.name)
            }
        }
    }
}
