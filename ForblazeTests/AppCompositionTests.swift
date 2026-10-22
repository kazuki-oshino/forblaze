import Testing
import ForblazeCore
import ForblazeApplication
@MainActor final class SpeechFake:SpeechService {
    var failPreparation=false
    var output=AsyncThrowingStream<RecognitionResult,Error>.makeStream()
    var onCloseInput:(()->Void)?
    func start(session:SessionID) async throws -> AsyncThrowingStream<RecognitionResult,Error> {
        if failPreparation {throw SessionFailure.preparation}
        output=AsyncThrowingStream<RecognitionResult,Error>.makeStream();return output.stream
    }
    func closeInput() {onCloseInput?()}
    func stopAudio() async {}
    func finalize() async throws {output.continuation.finish()}
    func cancel() async throws {output.continuation.finish()}
}
@MainActor final class ClockFake:SessionClock {
    func sleep(for duration:Duration) async throws {throw CancellationError()}
}
@MainActor final class TriggerFake:TriggerService {
    var keysReleased=true
    var onToggle:((BindingRevision)->Void)?
    var onKeyInput:((KeyInput)->Void)?
    var onManualInput:(()->Void)?
    func start() throws {}
    func stop() {}
    var enabled=false
    var binding:TriggerBinding?
    func setEnabled(_ enabled:Bool) {self.enabled=enabled}
    func apply(_ binding:TriggerBinding?,revision:BindingRevision) throws {self.binding=binding}
    func resetKeys() {}
}
@MainActor final class StoreFake:SettingsStore {
    var value=StoredSettings.missing
    func load() throws -> StoredSettings {value}
    func replace(_ value:StoredSettings) throws {self.value=value}
}
@MainActor struct AppCompositionTests {
    @Test func customSoundsFollowOneRecordingCycleAndDoNotRepeatDuringCleanup() async {
        let app=AppComposition(speech:SpeechFake(),clock:ClockFake(),trigger:TriggerFake(),store:StoreFake())
        var cues:[RecordingSoundCue]=[];app.onSoundCue={cue,completion in cues.append(cue);completion()}
        app.session.toggle();#expect(cues.isEmpty)
        await app.session.awaitPreparation();#expect(cues == [.start])
        app.session.toggle();#expect(cues == [.start,.stop])
        app.session.toggle();app.session.send(.manualInput);await app.session.awaitCleanup()
        #expect(cues == [.start,.stop])
        app.session.toggle();await app.session.awaitPreparation()
        await app.session.finishAndWait()
        #expect(cues == [.start,.stop,.start,.stop])
    }
    @Test(arguments:["manual","focus","permission","audio","settings","quit","suspended"])
    func interruptionsEndWithOneStopSound(reason:String) async {
        let trigger=TriggerFake(),app=AppComposition(speech:SpeechFake(),clock:ClockFake(),trigger:trigger,store:StoreFake())
        var cues:[RecordingSoundCue]=[];app.onSoundCue={cue,completion in cues.append(cue);completion()}
        trigger.onToggle?(.init(1));await app.session.awaitPreparation()
        switch reason {
        case "manual":trigger.onManualInput?()
        case "focus":app.session.send(.targetChanged(.init(2)))
        case "permission":app.session.send(.interrupt(.permissionLost))
        case "audio":app.session.send(.failed(app.session.state.session!,.audioDevice))
        case "settings":await app.session.finishAndWait()
        case "suspended":
            app.session.send(.injectionFailed(app.session.state.session!));#expect(cues == [.start])
            app.session.toggle()
        default:await app.session.shutdown()
        }
        #expect(cues == [.start,.stop])
        await app.session.awaitCleanup();app.session.send(.manualInput)
        #expect(cues == [.start,.stop])
    }
    @Test func disablingSoundsMutesBothCuesWithoutChangingRecording() async {
        let store=StoreFake();store.value = .valid(.init(sounds:false))
        let trigger=TriggerFake(),app=AppComposition(speech:SpeechFake(),clock:ClockFake(),trigger:trigger,store:store)
        var cues:[RecordingSoundCue]=[];app.onSoundCue={cue,completion in cues.append(cue);completion()}
        app.session.toggle();await app.session.awaitPreparation()
        #expect(app.session.state.phase == .listening)
        trigger.onManualInput?();await app.session.awaitCleanup()
        #expect(app.session.state.phase == .idle && cues.isEmpty)
    }
    @Test func failedOrCanceledPreparationAndStaleCallbacksAreSilent() async {
        let speech=SpeechFake(),app=AppComposition(speech:speech,clock:ClockFake(),trigger:TriggerFake(),store:StoreFake())
        var cues:[RecordingSoundCue]=[];app.onSoundCue={cue,completion in cues.append(cue);completion()}
        app.session.toggle();let old=app.session.state.session!
        app.session.toggle();await app.session.awaitCleanup()
        speech.failPreparation=true;app.session.toggle();await app.session.awaitPreparation();await app.session.awaitCleanup()
        #expect(cues.isEmpty)
        speech.failPreparation=false;app.session.toggle();await app.session.awaitPreparation()
        app.session.onStarted?(old);app.session.onStopped?(old)
        #expect(cues == [.start])
        await app.session.shutdown();app.session.onStopped?(old)
        #expect(cues == [.start,.stop])
    }

    @Test func editKeyFailureRestartAndStoredBindingUseOneLifecycle() async {
        let trigger=TriggerFake(),speech=SpeechFake(),store=StoreFake()
        let app=AppComposition(speech:speech,clock:ClockFake(),trigger:trigger,store:store)
        trigger.onToggle?(.init(1));await app.session.awaitPreparation()
        let previous=app.session.state.session
        trigger.onManualInput?()
        #expect(app.session.state.permission == .closed && app.model.title=="終了処理中")
        await app.session.awaitCleanup()
        #expect(app.model.title=="待機中" && app.model.errorText==nil)
        trigger.onToggle?(.init(1));await app.session.awaitPreparation()
        #expect(app.session.state.phase == .listening && app.session.state.session != previous)
        await app.session.finishAndWait()
        app.settings.beginCapture(isIdle:true)
        app.settings.receive(.init(.down,101))
        app.settings.save(isIdle:true)
        #expect(app.settings.current?.binding.keyCode==101 && app.settings.revision == .init(2))
        trigger.onToggle?(.init(1));#expect(app.session.state.phase == .idle)
        speech.failPreparation=true
        trigger.onToggle?(.init(2));await app.session.awaitPreparation();await app.session.awaitCleanup()
        #expect(app.session.state.phase == .idle && app.session.state.lastError == .preparation)
        speech.failPreparation=false
        trigger.onToggle?(.init(2));await app.session.awaitPreparation()
        #expect(app.session.state.phase == .listening && app.session.state.lastError==nil)
        await app.session.finishAndWait()
        #expect(app.session.state.phase == .idle && app.session.state.lastError==nil)
        let restoredTrigger=TriggerFake(),restored=AppComposition(speech:SpeechFake(),clock:ClockFake(),trigger:restoredTrigger,store:store)
        #expect(restoredTrigger.binding?.keyCode==101 && restoredTrigger.enabled && restored.session.state.phase == .idle)
    }

    @Test func missingPermissionsPresentInitialSetupOnce() {
        let app=AppComposition(speech:SpeechFake(),clock:ClockFake(),trigger:TriggerFake(),store:StoreFake())
        #expect(app.shouldPresentInitialSetup(for:.init()))
        #expect(!app.shouldPresentInitialSetup(for:.init()))
    }
    @Test func sameCompositionUsesOnlyFakesAndRejectsLateStartSound() async {
        let trigger=TriggerFake(),graph=AppComposition(speech:SpeechFake(),clock:ClockFake(),trigger:TriggerFake(),store:StoreFake())
        var started=0;graph.session.onStarted={_ in started+=1}
        graph.model.toggle();graph.model.toggle();await graph.session.awaitCleanup()
        #expect(graph.model.state.phase == .idle && started == 0)
        let app=AppComposition(speech:SpeechFake(),clock:ClockFake(),trigger:trigger,store:StoreFake())
        trigger.onToggle?(.init(0));#expect(app.session.state.phase == .idle)
        trigger.onToggle?(.init(1));await app.session.awaitPreparation()
        #expect(app.model.title == "認識中")
        await app.session.shutdown();#expect(app.model.title == "待機中")
    }
}
