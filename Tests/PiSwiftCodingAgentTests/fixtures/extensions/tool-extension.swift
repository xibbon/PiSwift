import PiExtensionSDK
import Foundation

@_cdecl("piExtensionMain")
public func piExtensionMain(_ raw: UnsafeMutableRawPointer) {
    withExtensionAPI(raw) { pi in
        // Schema: { "name": String }
        let parameters: [String: AnyCodable] = [
            "type": AnyCodable("object"),
            "properties": AnyCodable([
                "name": ["type": "string", "description": "Name to greet"] as [String: Any],
            ] as [String: Any]),
            "required": AnyCodable(["name"]),
        ]

        let helloTool = CustomTool(
            name: "ext-hello",
            label: "Extension Hello",
            description: "Greet someone — registered by an extension",
            parameters: parameters,
            execute: { _, params, _, _, _ in
                let name = (params["name"]?.value as? String) ?? "world"
                return AgentToolResult(content: [.text(TextContent(text: "Hello, \(name)!"))])
            }
        )

        pi.registerTool(helloTool)
    }
}
