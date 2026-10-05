import Foundation

public struct CodemodeExtensionOptions: Sendable {
    public var mode: CodemodeMode?
    public var inlineBudget: Double?
    public var models: Bool

    public init(mode: CodemodeMode? = nil, inlineBudget: Double? = nil, models: Bool = true) {
        self.mode = mode
        self.inlineBudget = inlineBudget
        self.models = models
    }
}

/// The built-in registers codemode inactive. A host can activate it with +codemode or --tools.
public func createCodemodeExtension(options: CodemodeExtensionOptions = .init()) -> InlineExtension {
    InlineExtension(name: "codemode", builtin: true, replaceable: true) { api in
        let toolOptions = CodemodeToolOptions(
            models: options.models,
            getToolNamespace: { name in api.getAllTools().first { $0.name == name }?.namespace },
            appendEntry: { type, data in
                api.appendEntry(type, ["set": data.set.mapValues(\.value), "delete": data.delete])
            },
            getMode: { options.mode ?? api.getSettings().codemode?.mode ?? .on },
            getInlineBudget: {
                let value = options.inlineBudget ?? api.getSettings().codemode?.inlineBudget
                return value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            },
            getToolGuidelines: {
                // Upstream builds a Map, so a later entry with the same name wins.
                Dictionary(api.getAllTools().map { ($0.name, $0.promptGuidelines ?? []) },
                           uniquingKeysWith: { _, last in last })
            })
        _ = api.registerTool(createCodemodeToolDefinition(options: toolOptions))
    }
}
