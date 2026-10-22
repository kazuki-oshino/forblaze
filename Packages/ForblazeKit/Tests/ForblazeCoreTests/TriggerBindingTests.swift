import Testing
import ForblazeCore
struct TriggerBindingTests {
    @Test func acceptsNonTextKeyOnly() {
        for code: UInt16 in [100, 53, 122, 116] { #expect(TriggerBinding(keyCode: code).isValid) }
        for code: UInt16 in [0, 36, 49, 56, 123, 999] { #expect(!TriggerBinding(keyCode: code).isValid) }
        #expect(!TriggerBinding(keyCode: 100, modifiers: 1).isValid)
        #expect(!TriggerBinding(version: 99, keyCode: 100).isValid)
    }
}
