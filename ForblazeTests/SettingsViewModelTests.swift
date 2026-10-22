import Testing
import ForblazeCore
import ForblazeApplication

@MainActor private final class FailingBlazeSettingsStore:SettingsStore {
    var value=StoredSettings.valid(.init(forblazeMode:true))
    var failNext=false
    func load() throws -> StoredSettings {value}
    func replace(_ value:StoredSettings) throws {
        if failNext {failNext=false;throw SettingsFailure.save}
        self.value=value
    }
}
@MainActor struct SettingsViewModelTests {
    @Test func failedToggleRestoresTheDisplayedAndStoredValue() async {
        let store=FailingBlazeSettingsStore()
        let app=AppComposition(speech:SpeechFake(),clock:ClockFake(),trigger:TriggerFake(),store:store)
        let model=SettingsViewModel(session:app.session,settings:app.settings)
        await model.open();store.failNext=true;model.forblazeMode=false
        #expect(model.error == .save && model.forblazeMode && app.settings.current?.forblazeMode == true)
        model.forblazeMode=false
        #expect(model.error == nil && !model.forblazeMode && app.settings.current?.forblazeMode == false)
    }
    @Test func allTogglesPersistImmediatelyAndSurviveClosingAndReopening() async {
        let store=StoreFake()
        let app=AppComposition(speech:SpeechFake(),clock:ClockFake(),trigger:TriggerFake(),store:store)
        let model=SettingsViewModel(session:app.session,settings:app.settings)
        await model.open()
        model.farField=false;model.sounds=false;model.punctuationCorrection=true;model.forblazeMode=true;model.copyToClipboard=true;model.muteOutputDuringDictation=true
        let expected=AppSettings(farField:false,sounds:false,punctuationCorrection:true,forblazeMode:true,copyToClipboard:true,muteOutputDuringDictation:true)
        #expect(app.settings.current == expected && store.value == .valid(expected))
        model.cancel();await model.open()
        #expect(!model.farField && !model.sounds && model.punctuationCorrection && model.forblazeMode && model.copyToClipboard && model.muteOutputDuringDictation)
        let restored=SettingsCoordinator(trigger:TriggerFake(),store:store)
        #expect(restored.current == expected)
    }
    @Test func toggleDoesNotCommitOrCancelAnUnconfirmedKey() async {
        let trigger=TriggerFake(),store=StoreFake()
        let app=AppComposition(speech:SpeechFake(),clock:ClockFake(),trigger:trigger,store:store)
        let model=SettingsViewModel(session:app.session,settings:app.settings)
        await model.open();model.beginCapture()
        app.settings.receive(.init(.down,101));app.settings.receive(.init(.up,101))
        model.sounds=false
        #expect(app.settings.current?.sounds == false && model.current == .defaultBinding)
        #expect(model.candidate == .init(keyCode:101) && model.capturing && !trigger.enabled)
        model.cancel()
        #expect(!model.sounds && model.current == .defaultBinding && trigger.enabled)
    }
    @Test func togglesCannotChangeBeforeOpeningOrDuringRecording() async {
        let store=StoreFake()
        let app=AppComposition(speech:SpeechFake(),clock:ClockFake(),trigger:TriggerFake(),store:store)
        let model=SettingsViewModel(session:app.session,settings:app.settings)
        model.sounds=false;#expect(model.sounds && app.settings.current?.sounds == true)
        await model.open();app.session.toggle();await app.session.awaitPreparation()
        model.sounds=false
        #expect(model.sounds && app.settings.current?.sounds == true)
        await app.session.shutdown()
    }
    @Test func rejectedRawRangeAndNumericFailureAreVisibleWithoutTranscript() async {
        let app=AppComposition(speech:SpeechFake(),clock:ClockFake(),trigger:TriggerFake(),store:StoreFake())
        let model=SettingsViewModel(session:app.session,settings:app.settings,observations:{[
            .init(.rejectedRange,range:.init(0.8,4),isFinal:true),.init(.resultsFailed,errorCode:42)
        ]})
        await model.open()
        #expect(model.observationSummary == "0.8〜4.0秒 確定 rejectedRange\nresultsFailed code=42")
    }

    @Test func loginStatusDistinguishesUnknownStateApprovalAndRegistrationFailure() {
        let app=AppComposition(speech:SpeechFake(),clock:ClockFake(),trigger:TriggerFake(),store:StoreFake())
        let model=SettingsViewModel(session:app.session,settings:app.settings)
        model.updateLogin(status:.unavailable,error:nil)
        #expect(!model.launchAtLogin && model.loginMessage == "ログイン時起動の状態をOSから確認できません。設定変更後に結果を確認してください")
        model.updateLogin(status:.approvalRequired,error:nil)
        #expect(!model.launchAtLogin && model.loginMessage == "システム設定でログイン時起動の承認が必要です")
        model.updateLogin(status:.unavailable,error:.registration)
        #expect(model.loginMessage == "ログイン時起動の設定を変更できませんでした")
        model.updateLogin(status:.enabled,error:nil)
        #expect(model.launchAtLogin && model.loginMessage==nil)
        model.updateLogin(status:.disabled,error:nil)
        #expect(!model.launchAtLogin && model.loginMessage==nil)
    }

    @Test func dictionaryIssuesShowLinesWithoutRules() {
        #expect(SettingsViewModel.warning([])==nil)
        #expect(SettingsViewModel.warning([.init(line:2,kind:.syntax),.init(line:5,kind:.selfExpansion)]) == "個人辞書の2、5行目に不正な規則があります。有効な行は使用します。")
    }
    @Test func openStopCaptureSaveCancelAndReset() async {
        let trigger=TriggerFake(),graph=AppComposition(speech:SpeechFake(),clock:ClockFake(),trigger:TriggerFake(),store:StoreFake())
        let app=AppComposition(speech:SpeechFake(),clock:ClockFake(),trigger:trigger,store:StoreFake())
        let model=SettingsViewModel(session:app.session,settings:app.settings)
        app.model.toggle();await app.session.awaitPreparation()
        #expect(!model.editingReady)
        await model.open();#expect(app.session.state.phase == .idle && model.editingReady)
        model.beginCapture();#expect(model.capturing && !trigger.enabled)
        app.settings.receive(.init(.down,36));#expect(model.error == .invalidCandidate && !model.canSave)
        trigger.keysReleased=false;app.settings.receive(.init(.down,101));#expect(!model.canSave)
        trigger.keysReleased=true;app.settings.receive(.init(.up,101));#expect(model.canSave)
        app.settings.receive(.init(.down,0));app.settings.receive(.init(.up,0))
        #expect(model.candidate == .init(keyCode:101) && model.canSave && model.error==nil)
        model.farField=false;model.save();#expect(model.current == .init(keyCode:101) && trigger.enabled)
        model.beginCapture();app.settings.receive(.init(.down,122));model.cancel();#expect(model.current == .init(keyCode:101) && model.candidate == nil)
        model.useDefault();model.save();#expect(model.current == .defaultBinding)
        await graph.session.shutdown()
    }
}
