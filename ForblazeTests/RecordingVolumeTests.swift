import Testing
import ForblazeApplication
import ForblazeCore

@MainActor private final class VolumeTrace {
    var events:[String]=[]
}
@MainActor private final class OutputVolumeFake:OutputVolumeControl {
    let trace:VolumeTrace
    var silenced=false
    init(_ trace:VolumeTrace) {self.trace=trace}
    func silence() {silenced=true;trace.events.append("silence")}
    func restore() {
        guard silenced else {return}
        silenced=false;trace.events.append("restore")
    }
}
@MainActor struct RecordingVolumeTests {
    @Test func waitsForStartSoundAndRestoresBeforeStopSound() async {
        let trace=VolumeTrace(),volume=OutputVolumeFake(trace),speech=SpeechFake(),store=StoreFake()
        store.value = .valid(.init(muteOutputDuringDictation:true))
        speech.onCloseInput={trace.events.append("close")}
        let app=AppComposition(speech:speech,clock:ClockFake(),trigger:TriggerFake(),store:store,outputVolume:volume)
        var completed:(()->Void)?
        app.onSoundCue={cue,completion in trace.events.append(cue == .start ? "start":"stop");completed=completion}
        app.session.toggle();await app.session.awaitPreparation()
        #expect(trace.events == ["start"])
        completed?();completed?()
        #expect(trace.events == ["start","silence"])
        app.session.toggle()
        #expect(trace.events == ["start","silence","close","restore","stop"])
        await app.session.awaitFinalization();await app.session.awaitCleanup()
        #expect(trace.events.filter {$0=="restore"}.count == 1)
    }
    @Test func stoppingBeforeTheCueEndsRejectsLateCompletionEvenAfterRestart() async {
        let trace=VolumeTrace(),volume=OutputVolumeFake(trace),store=StoreFake()
        store.value = .valid(.init(muteOutputDuringDictation:true))
        let app=AppComposition(speech:SpeechFake(),clock:ClockFake(),trigger:TriggerFake(),store:store,outputVolume:volume)
        var completions:[()->Void]=[]
        app.onSoundCue={cue,completion in if cue == .start {completions.append(completion)}}
        app.session.toggle();await app.session.awaitPreparation()
        await app.session.finishAndWait();completions[0]()
        #expect(trace.events.isEmpty)
        app.session.toggle();await app.session.awaitPreparation();completions[0]()
        #expect(trace.events.isEmpty)
        completions[1]();#expect(trace.events == ["silence"])
        await app.session.shutdown();#expect(trace.events == ["silence","restore"])
    }
    @Test(arguments:["manual","focus","permission","audio","recognition","settings","quit","sleep","suspended"])
    func everyRecordingExitRestoresVolume(reason:String) async {
        let trace=VolumeTrace(),volume=OutputVolumeFake(trace),store=StoreFake(),trigger=TriggerFake()
        store.value = .valid(.init(muteOutputDuringDictation:true))
        let app=AppComposition(speech:SpeechFake(),clock:ClockFake(),trigger:trigger,store:store,outputVolume:volume)
        app.onSoundCue={cue,completion in trace.events.append(cue == .start ? "start":"stop");completion()}
        app.session.toggle();await app.session.awaitPreparation()
        switch reason {
        case "manual":trigger.onManualInput?()
        case "focus":app.session.send(.targetChanged(.init(2)))
        case "permission":app.session.send(.interrupt(.permissionLost))
        case "audio":app.session.send(.failed(app.session.state.session!,.audioDevice))
        case "recognition":app.session.send(.failed(app.session.state.session!,.recognition))
        case "settings":await app.session.finishAndWait()
        case "sleep":InterruptionCoordinator(session:app.session,trigger:trigger).handle(.sleep)
        case "suspended":
            app.session.send(.injectionFailed(app.session.state.session!))
            #expect(volume.silenced)
            app.session.toggle()
        default:await app.session.shutdown()
        }
        await app.session.awaitFinalization();await app.session.awaitCleanup()
        #expect(trace.events == ["start","silence","restore","stop"])
    }
    @Test func defaultOffAndFailedPreparationLeaveVolumeAlone() async {
        let trace=VolumeTrace(),volume=OutputVolumeFake(trace),speech=SpeechFake(),store=StoreFake()
        let app=AppComposition(speech:speech,clock:ClockFake(),trigger:TriggerFake(),store:store,outputVolume:volume)
        app.onSoundCue={_,completion in completion()}
        app.session.toggle();await app.session.awaitPreparation();await app.session.finishAndWait()
        #expect(trace.events.isEmpty)
        app.settings.setOption(.muteOutputDuringDictation,enabled:true,isIdle:true)
        speech.failPreparation=true
        app.session.toggle();await app.session.awaitPreparation();await app.session.awaitCleanup()
        #expect(trace.events.isEmpty)
    }
    @Test func soundsDisabledStillSilencesAndRestores() async {
        let trace=VolumeTrace(),volume=OutputVolumeFake(trace),store=StoreFake()
        store.value = .valid(.init(sounds:false,muteOutputDuringDictation:true))
        let app=AppComposition(speech:SpeechFake(),clock:ClockFake(),trigger:TriggerFake(),store:store,outputVolume:volume)
        var cues=0;app.onSoundCue={_,_ in cues+=1}
        app.session.toggle();await app.session.awaitPreparation()
        #expect(trace.events == ["silence"])
        await app.session.finishAndWait()
        #expect(trace.events == ["silence","restore"] && cues == 0)
    }
}
