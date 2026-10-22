import Testing
import ForblazeCore
import ForblazeApplication

@MainActor private final class GuidanceFocus:FocusService {
    var onChange:((FocusSnapshot)->Void)?
    var snapshot=FocusSnapshot(target:.init(id:nil,capability:.unavailable),epoch:.init(1))
    func read() async -> FocusSnapshot {snapshot}
    func start() {}
    func stop() async {}
}
private actor GuidanceDictionary:DictionaryStore {
    func load() -> DictionarySnapshot {.init(samples:"",personal:"")}
    func save(_ text:String) {}
}
@MainActor private final class GuidanceSink:TextSink {
    var calls=0
    func send(_ edit:TextEdit,context:InjectionContext,permit:@escaping @MainActor ()->Bool) async -> TextAcknowledgment {
        calls+=1
        return .init(deleted:0,inserted:"",completed:false)
    }
}
@MainActor private final class GuidanceSpeech:SpeechService {
    var starts=0
    var onStart:(()->Void)?
    var cleanupFails=false
    private var output=AsyncThrowingStream<RecognitionResult,Error>.makeStream()
    func start(session:SessionID) async throws -> AsyncThrowingStream<RecognitionResult,Error> {
        starts+=1;onStart?()
        output=AsyncThrowingStream<RecognitionResult,Error>.makeStream();return output.stream
    }
    func closeInput() {}
    func stopAudio() async {}
    func finalize() async throws {output.continuation.finish()}
    func cancel() async throws {
        if cleanupFails {throw SessionFailure.cleanup}
        output.continuation.finish()
    }
}

@MainActor struct InputGuidanceTests {
    @Test func compositionConnectsClipboardPreferenceToTheInputSession() {
        let input=LiveInputSession(focus:GuidanceFocus(),dictionary:GuidanceDictionary(),sink:GuidanceSink(),clock:ClockFake())
        let store=StoreFake();store.value = .valid(.init(copyToClipboard:true))
        let app=AppComposition(speech:SpeechFake(),clock:ClockFake(),trigger:TriggerFake(),store:store,input:input)
        #expect(input.copyToClipboardEnabled())
        app.settings.setOption(.copyToClipboard,enabled:false,isIdle:true)
        #expect(!input.copyToClipboardEnabled())
    }

    @Test(arguments:[TargetCapability.unavailable,.noneditable,.protected])
    func repeatedRejectedStartDismissesNoticeWithoutRecording(capability:TargetCapability) async {
        let focus=GuidanceFocus(),sink=GuidanceSink(),trigger=TriggerFake(),speech=GuidanceSpeech()
        focus.snapshot = .init(target:.init(id:nil,capability:capability),epoch:.init(1))
        let input=LiveInputSession(focus:focus,dictionary:GuidanceDictionary(),sink:sink,clock:ClockFake())
        let app=AppComposition(speech:speech,clock:ClockFake(),trigger:trigger,store:StoreFake(),input:input)
        var cues:[RecordingSoundCue]=[];app.onSoundCue={cue,completion in cues.append(cue);completion()}
        trigger.onToggle?(.init(1));await app.session.awaitPreparation();await app.session.awaitCleanup()
        #expect(app.model.errorText != nil && app.model.recoveryHelp != nil)
        trigger.onToggle?(.init(1));await app.session.awaitPreparation();await app.session.awaitCleanup()
        #expect(app.session.state.phase == .idle && app.session.state.session==nil)
        #expect(app.session.state.lastError==nil && app.session.state.failurePhase==nil)
        #expect(app.model.errorText==nil && app.model.recoveryHelp==nil)
        #expect(speech.starts==0 && sink.calls==0 && cues.isEmpty)
        trigger.onToggle?(.init(1));await app.session.awaitPreparation();await app.session.awaitCleanup()
        #expect(app.model.errorText != nil && app.model.recoveryHelp != nil)
        focus.snapshot = .init(target:.init(id:.init(process:1,element:1),capability:.editable),epoch:.init(2))
        trigger.onToggle?(.init(1));await app.session.awaitPreparation()
        #expect(app.session.state.phase == .listening && speech.starts==1 && cues == [.start])
        await app.session.shutdown()
    }

    @Test func targetLostAfterRecordingCanBeDismissedAtAnInvalidLocation() async {
        let focus=GuidanceFocus(),speech=GuidanceSpeech(),trigger=TriggerFake()
        focus.snapshot = .init(target:.init(id:.init(process:1,element:1),capability:.editable),epoch:.init(1))
        let input=LiveInputSession(focus:focus,dictionary:GuidanceDictionary(),sink:GuidanceSink(),clock:ClockFake())
        let app=AppComposition(speech:speech,clock:ClockFake(),trigger:trigger,store:StoreFake(),input:input)
        trigger.onToggle?(.init(1));await app.session.awaitPreparation()
        focus.snapshot = .init(target:.init(id:nil,capability:.unavailable),epoch:.init(2))
        focus.onChange?(focus.snapshot);await app.session.awaitCleanup()
        #expect(app.model.errorText=="入力先を確認できなくなったため、音声入力を終了しました")
        trigger.onToggle?(.init(1));await app.session.awaitPreparation();await app.session.awaitCleanup()
        #expect(app.session.state.phase == .idle && app.model.errorText==nil && speech.starts==1)
    }

    @Test func retryStillReportsTargetLostAfterSpeechStarts() async {
        let focus=GuidanceFocus(),speech=GuidanceSpeech(),trigger=TriggerFake()
        let input=LiveInputSession(focus:focus,dictionary:GuidanceDictionary(),sink:GuidanceSink(),clock:ClockFake())
        let app=AppComposition(speech:speech,clock:ClockFake(),trigger:trigger,store:StoreFake(),input:input)
        trigger.onToggle?(.init(1));await app.session.awaitPreparation();await app.session.awaitCleanup()
        focus.snapshot = .init(target:.init(id:.init(process:1,element:1),capability:.editable),epoch:.init(2))
        speech.onStart={focus.snapshot = .init(target:.init(id:nil,capability:.unavailable),epoch:.init(3))}
        trigger.onToggle?(.init(1));await app.session.awaitPreparation();await app.session.awaitCleanup()
        #expect(app.session.state.phase == .idle && speech.starts==1)
        #expect(app.session.state.lastError == .target(.unavailable) && app.model.errorText != nil)
    }

    @Test func dismissingNoticeDoesNotHideCleanupFailure() async {
        let focus=GuidanceFocus(),speech=GuidanceSpeech(),trigger=TriggerFake()
        let input=LiveInputSession(focus:focus,dictionary:GuidanceDictionary(),sink:GuidanceSink(),clock:ClockFake())
        let app=AppComposition(speech:speech,clock:ClockFake(),trigger:trigger,store:StoreFake(),input:input)
        trigger.onToggle?(.init(1));await app.session.awaitPreparation();await app.session.awaitCleanup()
        speech.cleanupFails=true
        trigger.onToggle?(.init(1));await app.session.awaitPreparation();await app.session.awaitCleanup()
        #expect(app.session.state.phase == .stopping && app.session.state.lastError == .cleanup)
        #expect(app.model.errorText=="終了処理が完了していません" && speech.starts==0)
    }

    @Test func rejectedStartIsSilentAndOneKeyPressRetriesWithoutOldCallbacksInterfering() async throws {
        let focus=GuidanceFocus(),sink=GuidanceSink(),trigger=TriggerFake()
        let input=LiveInputSession(focus:focus,dictionary:GuidanceDictionary(),sink:sink,clock:ClockFake())
        let app=AppComposition(speech:SpeechFake(),clock:ClockFake(),trigger:trigger,store:StoreFake(),input:input)
        var cues:[RecordingSoundCue]=[];app.onSoundCue={cue,completion in cues.append(cue);completion()}
        trigger.onToggle?(.init(1));let old=try #require(app.session.state.session)
        await app.session.awaitPreparation();await app.session.awaitCleanup()
        #expect(app.model.errorText=="入力欄を確認できません" && app.model.recoveryHelp != nil)
        #expect(cues.isEmpty && sink.calls==0)
        focus.snapshot = .init(target:.init(id:.init(process:1,element:1),capability:.editable),epoch:.init(2))
        trigger.onToggle?(.init(1))
        #expect(app.model.errorText==nil && app.model.recoveryHelp==nil)
        await app.session.awaitPreparation()
        #expect(app.session.state.phase == .listening && cues == [.start])
        input.onTargetChanged?(old,.init(3),.unavailable)
        app.session.send(.failed(old,.target(.protected)))
        #expect(app.session.state.phase == .listening && app.session.state.lastError==nil)
        trigger.onManualInput?()
        focus.onChange?(.init(target:.init(id:nil,capability:.unavailable),epoch:.init(3)))
        await app.session.awaitCleanup()
        #expect(app.model.errorText==nil && app.model.recoveryHelp==nil && cues == [.start,.stop])
        #expect(app.session.state.phase == .idle && sink.calls==0)
    }
}
