import Testing
import ForblazeCore
import ForblazeMacOS
@MainActor struct TriggerMonitorTests {
    @Test func routesWithoutCreatingTap() throws {
        let m=CGEventTriggerMonitor();try m.apply(.defaultBinding,revision:.init(1))
        var toggles=0, keys=0, disabled=0
        m.onToggle={_ in toggles+=1};m.onKeyInput={_ in keys+=1};m.onDisabled={disabled+=1}
        #expect(m.process(.init(.down)) == .toggle)
        #expect(!m.keysReleased && toggles == 1)
        #expect(m.process(.init(.down,isRepeat:true)) == .consume)
        #expect(m.process(.init(.up)) == .consume && m.keysReleased)
        m.setEnabled(false)
        #expect(m.process(.init(.down)) == .pass && toggles == 1)
        #expect(m.process(.init(.up)) == .pass)
        #expect(m.process(.init(.down,36,modifiers:1)) == .pass)
        #expect(keys > 0)
        m.disable();#expect(disabled == 1 && m.keysReleased)
        #expect(m.process(.init(.down)) == .pass)
    }
}
