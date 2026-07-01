import PiExtensionSDK

@_cdecl("piExtensionMain")
public func piExtensionMain(_ raw: UnsafeMutableRawPointer) {
    withExtensionAPI(raw) { pi in
        pi.on("resources_discover") { (event: ResourcesDiscoverEvent, ctx: HookContext) in
            ResourcesDiscoverResult(promptPaths: ["extension-prompt.md"])
        }
    }
}
