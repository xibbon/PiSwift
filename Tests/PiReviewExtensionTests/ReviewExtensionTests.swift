import Foundation
import Testing
@testable import PiReviewExtension
import PiSwiftCodingAgent

@Suite("PiReviewExtension")
struct ReviewExtensionTests {
    @Test("inline extension registers review commands and lifecycle handlers")
    func inlineExtensionRegisters() throws {
        let eventBus = createEventBus()
        let result = ExtensionLoader.load(PiReview.inlineExtension, cwd: FileManager.default.temporaryDirectory.path, eventBus: eventBus)

        #expect(result.error == nil)
        let hook = try #require(result.hook)

        #expect(hook.commands.keys.contains("review"))
        #expect(hook.commands.keys.contains("end-review"))
        #expect(hook.handlers.keys.contains("session_start"))
        #expect(hook.handlers.keys.contains("session_tree"))
        #expect(hook.path == "<inline:review>")
    }

    @Test("register is idempotent across separate API instances")
    func registerOnFreshAPI() {
        let api = HookAPI(events: createEventBus(), hookPath: "<test:review>")
        PiReview.register(api)

        #expect(api.commands.keys.contains("review"))
        #expect(api.commands.keys.contains("end-review"))
        #expect(api.commands["review"]?.description?.isEmpty == false)
    }
}
