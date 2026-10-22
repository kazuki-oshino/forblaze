import Testing
import ForblazeCore
struct TriggerRuleTests {
    @Test func onePressOneToggleAndMatchedRelease() {
        var rule = TriggerRule()
        #expect(rule.handle(.init(.down)) == .toggle)
        rule.enabled = false
        #expect(rule.handle(.init(.down, isRepeat: true)) == .consume)
        #expect(rule.handle(.init(.up, modifiers: 1)) == .consume)
        #expect(rule.handle(.init(.down)) == .pass)
        rule.enabled = true
        #expect(rule.handle(.init(.down, modifiers: 1)) == .pass)
        #expect(rule.handle(.init(.up)) == .pass)
        #expect(rule.handle(.init(.down, revision: .init(0))) == .pass)
        #expect(rule.handle(.init(.down)) == .toggle)
        rule.binding = .init(keyCode: 101); rule.revision = .init(2)
        #expect(rule.handle(.init(.up)) == .consume)
        #expect(rule.handle(.init(.down, 100, revision: .init(2))) == .pass)
        #expect(rule.handle(.init(.down, 101, revision: .init(2))) == .toggle)
        rule.reset()
        #expect(rule.handle(.init(.up, 101, revision: .init(2))) == .pass)
    }
    @Test func unpairedRepeatNeverStarts() {
        var rule = TriggerRule()
        #expect(rule.handle(.init(.down, isRepeat: true)) == .pass)
        for code: UInt16 in [0, 36, 49, 123] { #expect(rule.handle(.init(.down, code)) == .pass) }
    }
}
