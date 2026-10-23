import Testing
@testable import PiSwiftCodingAgent

// Upstream custom UI takes the TUI OverlayOptions, which include nonCapturing.
@Test func hookOverlayOptionsCarryNonCapturing() {
    #expect(HookOverlayOptions().nonCapturing == false)
    #expect(HookOverlayOptions(anchor: nil, nonCapturing: true).nonCapturing == true)
}
