import Foundation
import Synchronization

public enum HarnessDefinitionError: Error, Sendable, Equatable, CustomStringConvertible {
    case duplicateTool(extensionName: String, name: String)
    case duplicateSection(extensionName: String, key: String)
    case invalidSectionKey(String)
    case reservedSectionKey(String)
    case renamedWrapper(target: String, name: String)
    case argumentsMustBeObject(String)
    case duplicateTask(extensionName: String, name: String)
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

public struct RegistrySnapshot: Sendable {
    private let extensions: [Extension]
    private let builtins: [AnyTaskDefinition]
    public init(extensions: [Extension] = []) {
        self.extensions = extensions; builtins = AnyTaskDefinition.builtins
    }
    internal init(extensions: [Extension], builtins: [AnyTaskDefinition]) {
        self.extensions = extensions; self.builtins = builtins
    }
    public func installed() -> [Extension] { extensions }
    public func `extension`(name: String) -> Extension? { extensions.first { harnessNamesEqual($0.name, name) } }
    public func tools() -> [(extension: Extension, tool: ToolRegistration)] {
        extensions.flatMap { item in item.tools.map { (item, $0) } }
    }
    public func sections() -> [(extension: Extension, section: PromptSection)] {
        extensions.flatMap { item in item.sections.map { (item, $0) } }
    }
    public func tasks() -> [AnyTaskDefinition] { builtins + extensions.flatMap(\.tasks) }
    public func task(name: String) -> AnyTaskDefinition? { tasks().first { harnessNamesEqual($0.name, name) } }
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
    private let builtins: [AnyTaskDefinition]
    public init() { builtins = AnyTaskDefinition.builtins }
    internal init(builtins: [AnyTaskDefinition]) {
        self.builtins = builtins
        state.withLock { $0.current = RegistrySnapshot(extensions: [], builtins: builtins) }
    }
    public func snapshot() -> RegistrySnapshot { state.withLock { $0.current } }
    public func subscribe(_ listener: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        let id = UUID()
        state.withLock { $0.listeners.append((id, listener)) }
        return { [self] in state.withLock { $0.listeners.removeAll { $0.0 == id } } }
    }
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
    public func uninstall(_ extensionValue: Extension) { uninstall(name: extensionValue.name) }
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
public func createRegistry() -> Registry {
    Registry(builtins: [generationTask.eraseToAnyTaskDefinition(), toolTask.eraseToAnyTaskDefinition(),
                        compactionTask.eraseToAnyTaskDefinition()])
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
