import Foundation
import Darwin
import PiSwiftAI

/// Loads a compiled extension dylib via `dlopen` and invokes its entry point.
public struct ExtensionDylibLoader {

    /// Global store that retains HookAPI instances so they aren't deallocated
    /// while the extension dylib is still loaded.
    private static let apiStore = ExtensionAPIStore()

    /// Load a compiled extension dylib and return the resulting `LoadedHook`.
    ///
    /// Steps:
    /// 1. `dlopen` the dylib with `RTLD_NOW | RTLD_LOCAL`
    /// 2. `dlsym` for `piExtensionMain`
    /// 3. Create a `HookAPI`, pass it to the entry point
    /// 4. Extract registered handlers into a `LoadedHook`
    public static func loadAndInitialize(
        dylibPath: String,
        extensionPath: String,
        eventBus: EventBus,
        cwd: String
    ) throws -> LoadedHook {
        // RTLD_LOCAL prevents symbol collisions between extensions
        guard let handle = dlopen(dylibPath, RTLD_NOW | RTLD_LOCAL) else {
            let errorMsg = String(cString: dlerror())
            throw ExtensionLoadError.loadError(path: extensionPath, error: "dlopen failed: \(errorMsg)")
        }

        guard let sym = dlsym(handle, "piExtensionMain") else {
            let errorMsg = String(cString: dlerror())
            dlclose(handle)
            throw ExtensionLoadError.loadError(
                path: extensionPath,
                error: "dlsym(piExtensionMain) failed: \(errorMsg)"
            )
        }

        let entryPoint = unsafeBitCast(sym, to: (@convention(c) (UnsafeMutableRawPointer) -> Void).self)

        let api = HookAPI(events: eventBus, hookPath: extensionPath)
        api.setExecCwd(cwd)

        // Keep the API alive for the lifetime of the process.
        apiStore.add(api)

        // Call the extension's entry point, passing the API as an opaque pointer.
        let opaqueAPI = Unmanaged.passUnretained(api).toOpaque()
        entryPoint(opaqueAPI)

        return LoadedHook(
            path: extensionPath,
            resolvedPath: extensionPath,
            handlers: api.handlers,
            messageRenderers: api.messageRenderers,
            commands: api.commands,
            flags: api.flags,
            shortcuts: api.shortcuts,
            tools: api.tools,
            providerRegistrations: api.providerRegistrations,
            setSendMessageHandler: api.setSendMessageHandler,
            setAppendEntryHandler: api.setAppendEntryHandler,
            setSetSessionNameHandler: api.setSetSessionNameHandler,
            setGetSessionNameHandler: api.setGetSessionNameHandler,
            setGetActiveToolsHandler: api.setGetActiveToolsHandler,
            setGetAllToolsHandler: api.setGetAllToolsHandler,
            setSetActiveToolsHandler: api.setSetActiveToolsHandler,
            setRegisterProviderHandler: api.setRegisterProviderHandler,
            setUnregisterProviderHandler: api.setUnregisterProviderHandler,
            setFlagValue: api.setFlagValue,
            isExtension: true
        )
    }
}

/// Thread-safe store that retains extension HookAPI instances.
private final class ExtensionAPIStore: Sendable {
    private let state = LockedState<[HookAPI]>([])

    func add(_ api: HookAPI) {
        state.withLock { apis in
            apis.append(api)
        }
    }
}
