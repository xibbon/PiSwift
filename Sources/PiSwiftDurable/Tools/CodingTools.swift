/// The read, write, edit, and bash tools. A host must install this extension explicitly.
/// On iOS, use the read, write, and edit factories if the host has no remote shell.
/// Local bash calls on iOS produce a normal harness error result with shellUnavailable.
public var CodingTools: Extension {
    get throws {
        try createCodingTools()
    }
}

/// Creates the coding tools with an optional image processor for the read tool.
public func createCodingTools(images: (any ImageProcessor)? = nil) throws -> Extension {
    try defineExtension(Extension(name: "coding-tools", tools: [
        createReadTool(images: images), createWriteTool(), createEditTool(), createBashTool()
    ]))
}
