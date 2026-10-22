import Testing
import ForblazeCore
import ForblazeApplication
@MainActor final class FakeTrigger:TriggerService {
    var keysReleased=true
    var onToggle:((BindingRevision)->Void)?
    var onKeyInput:((KeyInput)->Void)?
    var enabled=false
    var binding:TriggerBinding?
    var calls:[String]=[]
    var failApplyCount=0
    func start() throws {}
    func stop() {}
    func setEnabled(_ enabled:Bool) {self.enabled=enabled;calls.append(enabled ? "enable":"disable")}
    func apply(_ binding:TriggerBinding?,revision:BindingRevision) throws {
        calls.append("apply")
        if failApplyCount>0 {failApplyCount-=1;throw SettingsFailure.apply}
        self.binding=binding
    }
    func resetKeys() {}
}
@MainActor final class FakeStore:SettingsStore {
    var value:StoredSettings = .valid(.init())
    var failSaveCount=0
    func load() throws -> StoredSettings {value}
    func replace(_ value:StoredSettings) throws {
        self.value=value
        if failSaveCount>0 {failSaveCount-=1;throw SettingsFailure.save}
    }
}
@MainActor struct SettingsCoordinatorTests {
    @Test func performanceSettingsPreserveOldDefaultsRollbackAndSurviveKeyChanges() {
        let store=FakeStore(),settings=SettingsCoordinator(trigger:FakeTrigger(),store:store)
        #expect(settings.current?.speechBufferSize == .standard && settings.current?.prewarmRecognition==false)
        settings.setBufferSize(.small,isIdle:true)
        settings.setOption(.prewarmRecognition,enabled:true,isIdle:true)
        settings.setOption(.balancedInput,enabled:true,isIdle:true)
        settings.useDefault(isIdle:true);settings.save(isIdle:true)
        #expect(settings.current?.speechBufferSize == .small && settings.current?.prewarmRecognition==true && settings.current?.balancedInput==true)
        store.failSaveCount=1;settings.setBufferSize(.smallest,isIdle:true)
        #expect(settings.current?.speechBufferSize == .small && settings.error == .save)
        settings.setBufferSize(.standard,isIdle:false)
        #expect(settings.current?.speechBufferSize == .small && settings.error == .sessionActive)
    }
    @Test func clipboardTogglePersistsRollsBackAndSurvivesKeyChanges() {
        let store=FakeStore(),settings=SettingsCoordinator(trigger:FakeTrigger(),store:store)
        settings.setOption(.copyToClipboard,enabled:true,isIdle:true)
        #expect(settings.current?.copyToClipboard == true && store.value == .valid(.init(copyToClipboard:true)))
        settings.useDefault(isIdle:true);settings.save(isIdle:true)
        #expect(settings.current?.copyToClipboard == true)
        settings.setOption(.copyToClipboard,enabled:false,isIdle:false)
        #expect(settings.current?.copyToClipboard == true && settings.error == .sessionActive)
        store.failSaveCount=1
        settings.setOption(.copyToClipboard,enabled:false,isIdle:true)
        #expect(settings.current?.copyToClipboard == true && settings.error == .save)
        settings.setOption(.copyToClipboard,enabled:false,isIdle:true)
        #expect(settings.current?.copyToClipboard == false && settings.error == nil)
    }
    @Test func optionSavePreservesCaptureRevisionAndHeldKeys() {
        let trigger=FakeTrigger(),store=FakeStore(),settings=SettingsCoordinator(trigger:trigger,store:store)
        settings.restoreAtStartup();settings.beginCapture(isIdle:true)
        trigger.keysReleased=false;settings.receive(.init(.down,101))
        let calls=trigger.calls
        settings.setOption(.sounds,enabled:false,isIdle:true)
        #expect(settings.current?.sounds == false && settings.current?.binding == .defaultBinding)
        #expect(settings.candidate == .init(keyCode:101) && settings.capturing)
        #expect(settings.revision == .init(1) && trigger.calls == calls && !trigger.enabled)
    }
    @Test func optionFailureRollsBackAndRestoreFailureDisablesTrigger() {
        for failures in [1,2] {
            let trigger=FakeTrigger(),store=FakeStore(),settings=SettingsCoordinator(trigger:trigger,store:store)
            settings.restoreAtStartup();store.failSaveCount=failures
            settings.setOption(.sounds,enabled:false,isIdle:true)
            #expect(settings.current?.sounds == true && store.value == .valid(.init()))
            #expect(settings.error == (failures==1 ? .save:.restore))
            #expect(trigger.enabled == (failures==1))
            if failures==2 {
                settings.setOption(.sounds,enabled:false,isIdle:false)
                #expect(settings.error == .restore)
                settings.setOption(.forblazeMode,enabled:true,isIdle:true)
                #expect(settings.error == .restore && settings.current?.forblazeMode == false && !trigger.enabled)
                settings.beginCapture(isIdle:true)
                settings.setOption(.forblazeMode,enabled:true,isIdle:true)
                settings.cancel();settings.restoreAtStartup()
                #expect(settings.error == .restore && settings.current?.forblazeMode == false && !trigger.enabled)
                settings.useDefault(isIdle:true);settings.save(isIdle:true)
                #expect(settings.error == nil && trigger.enabled)
            }
        }
    }
    @Test func optionSaveDoesNotHideAKeyApplicationFailure() {
        let trigger=FakeTrigger(),store=FakeStore(),settings=SettingsCoordinator(trigger:trigger,store:store)
        trigger.failApplyCount=1;settings.restoreAtStartup()
        settings.setOption(.sounds,enabled:false,isIdle:true)
        #expect(settings.error == .apply && !trigger.enabled && settings.current?.sounds == false)
    }
    @Test func optionDoesNotOverwriteCorruptOrActiveSettings() {
        let trigger=FakeTrigger(),store=FakeStore(),settings=SettingsCoordinator(trigger:trigger,store:store)
        settings.setOption(.sounds,enabled:false,isIdle:false)
        #expect(settings.error == .sessionActive && settings.current?.sounds == true)
        store.value = .invalid
        let corrupt=SettingsCoordinator(trigger:trigger,store:store)
        corrupt.setOption(.sounds,enabled:false,isIdle:true)
        #expect(corrupt.error == .corrupt && store.value == .invalid)
    }
    @Test func blazeSaveFailureRestoresTheWholePreviousConfiguration() {
        let trigger=FakeTrigger(),store=FakeStore()
        let previous=AppSettings(binding:.init(keyCode:101),farField:false,sounds:false,punctuationCorrection:true,forblazeMode:true)
        store.value = .valid(previous)
        let settings=SettingsCoordinator(trigger:trigger,store:store)
        settings.restoreAtStartup();store.failSaveCount=1
        settings.save(isIdle:true,forblazeMode:false)
        #expect(settings.error == .save && settings.current == previous && store.value == .valid(previous))
        settings.save(isIdle:true,farField:false,sounds:false)
        #expect(settings.current?.forblazeMode == true && settings.current?.punctuationCorrection == true)
    }
    @Test func releasedCandidateSurvivesTypingUntilSaveCancelOrRecapture() {
        let trigger=FakeTrigger(),store=FakeStore(),binding=TriggerBinding(keyCode:101)
        let settings=SettingsCoordinator(trigger:trigger,store:store);settings.restoreAtStartup()
        settings.beginCapture(isIdle:true);trigger.keysReleased=false
        settings.receive(.init(.down,101));trigger.keysReleased=true;settings.receive(.init(.up,101))
        trigger.keysReleased=false;settings.receive(.init(.down,0))
        #expect(settings.candidate==binding && settings.error==nil && !trigger.enabled)
        settings.save(isIdle:true);#expect(settings.error == .keyHeld && settings.current?.binding == .defaultBinding)
        trigger.keysReleased=true;settings.receive(.init(.up,0))
        settings.save(isIdle:true)
        #expect(settings.current?.binding==binding && trigger.enabled && settings.revision == .init(2))
        settings.beginCapture(isIdle:true);settings.receive(.init(.down,122));settings.receive(.init(.up,122))
        settings.cancel();#expect(settings.candidate==nil && settings.current?.binding==binding)
        settings.beginCapture(isIdle:true);settings.receive(.init(.down,36))
        #expect(settings.candidate==nil && settings.error == .invalidCandidate)
        settings.receive(.init(.down,109));settings.receive(.init(.up,109))
        #expect(settings.candidate == .init(keyCode:109) && settings.error==nil)
    }
    @Test func recaptureDoesNotResumeToggleFromAnEarlierCancelWhileHeld() {
        let trigger=FakeTrigger(),store=FakeStore(),settings=SettingsCoordinator(trigger:trigger,store:store)
        settings.restoreAtStartup();settings.beginCapture(isIdle:true)
        trigger.keysReleased=false;settings.receive(.init(.down,101));settings.cancel()
        settings.beginCapture(isIdle:true)
        trigger.keysReleased=true;settings.receive(.init(.up,101))
        #expect(settings.capturing && settings.candidate==nil && !trigger.enabled)
    }
    @Test func defaultCandidateIsNotOverwrittenByLaterTyping() {
        let trigger=FakeTrigger(),store=FakeStore(),settings=SettingsCoordinator(trigger:trigger,store:store)
        settings.useDefault(isIdle:true);settings.receive(.init(.down,0));settings.receive(.init(.up,0))
        #expect(settings.candidate == .defaultBinding && settings.error==nil)
        settings.save(isIdle:true)
        #expect(settings.current?.binding == .defaultBinding && trigger.enabled)
    }
    @Test func applySaveReleaseCancelAndRevision() {
        let t=FakeTrigger(),store=FakeStore();let c=SettingsCoordinator(trigger:t,store:store)
        c.restoreAtStartup();#expect(t.enabled && t.binding == .defaultBinding)
        c.beginCapture(isIdle:false);#expect(c.error == .sessionActive)
        c.beginCapture(isIdle:true);#expect(!t.enabled && c.capturing)
        c.receive(.init(.down,36));#expect(c.error == .invalidCandidate && c.candidate == nil)
        c.receive(.init(.down,101));t.keysReleased=false;c.save(isIdle:true)
        #expect(c.error == .keyHeld && c.revision == .init(1))
        t.keysReleased=true;c.save(isIdle:true,farField:false)
        #expect(t.binding == .init(keyCode:101) && t.enabled && c.revision == .init(2))
        #expect(c.current?.farField == false)
        c.beginCapture(isIdle:true);c.receive(.init(.down,122));c.cancel()
        #expect(t.binding == .init(keyCode:101) && c.candidate == nil && t.enabled)
        c.useDefault(isIdle:true);c.save(isIdle:true);#expect(t.binding == .defaultBinding)
    }
    @Test func failuresRestorePreviousOrDisable() {
        for (applyFailures,saveFailures,expected) in [(1,0,SettingsFailure.apply),(0,1,.save),(2,0,.restore),(0,2,.restore)] {
            let t=FakeTrigger(),store=FakeStore();let c=SettingsCoordinator(trigger:t,store:store);c.restoreAtStartup()
            c.beginCapture(isIdle:true);c.receive(.init(.down,101));t.failApplyCount=applyFailures;store.failSaveCount=saveFailures
            c.save(isIdle:true)
            #expect(c.error == expected && c.revision == .init(1))
            #expect(t.enabled == (expected != .restore))
            #expect(c.current?.binding == .defaultBinding)
        }
    }
    @Test func corruptedSettingsNeverActivateOrOverwrite() {
        let t=FakeTrigger(),store=FakeStore();store.value = .invalid
        let c=SettingsCoordinator(trigger:t,store:store);c.restoreAtStartup()
        #expect(!t.enabled && c.error == .corrupt && store.value == .invalid)
    }
}
