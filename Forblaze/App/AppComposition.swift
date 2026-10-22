import ForblazeCore
import ForblazeApplication
/// 本番とテストで同じ初期化経路にサービスを渡す。
@MainActor final class AppComposition {
    let session:SessionCoordinator
    let settings:SettingsCoordinator
    let model:DictationViewModel
    private var initialSetupProcessed=false
    private var recordingSession:SessionID?
    private var pendingSilence:SessionID?
    private let outputVolume:(any OutputVolumeControl)?
    func shouldPresentInitialSetup(for availability:Availability) -> Bool {
        guard !initialSetupProcessed else {return false}
        initialSetupProcessed=true
        return !availability.canStart
    }
    var onChange:(()->Void)?
    var onSoundCue:((RecordingSoundCue,@escaping ()->Void)->Void)?
    init(speech:any SpeechService,clock:any SessionClock,trigger:any TriggerService,store:any SettingsStore,canStart:@escaping ()->Bool={true},input:LiveInputSession?=nil,diagnostics:DiagnosticRecorder?=nil,outputVolume:(any OutputVolumeControl)?=nil) {
        self.outputVolume=outputVolume
        session=SessionCoordinator(speech:speech,clock:clock,canStart:canStart,input:input,diagnostics:diagnostics)
        settings=SettingsCoordinator(trigger:trigger,store:store)
        let settings=self.settings
        input?.punctuationEnabled={ [weak settings] in settings?.current?.punctuationCorrection ?? false }
        input?.copyToClipboardEnabled={ [weak settings] in settings?.current?.copyToClipboard ?? false }
        input?.balancedInputEnabled={ [weak settings] in settings?.current?.balancedInput ?? false }
        let session=self.session
        model=DictationViewModel(toggle:{ [weak session] in session?.toggle() })
        session.onChange={ [weak self] state in
            guard let self else {return}
            if state.phase == .idle {self.restoreOutputVolume()}
            self.model.update(state:state,preview:self.session.preview);self.onChange?()
        }
        session.onStarted={ [weak self] id in
            guard let self,self.session.state.session==id,self.session.state.phase == .listening,
                  self.recordingSession != id else {return}
            self.recordingSession=id
            if self.settings.current?.muteOutputDuringDictation == true {self.pendingSilence=id}
            let completed={ [weak self] in
                guard let self,self.pendingSilence==id,self.recordingSession==id,
                      self.session.state.session==id,self.session.state.phase == .listening else {return}
                self.pendingSilence=nil
                self.outputVolume?.silence()
            }
            if self.settings.current?.sounds ?? true,let play=self.onSoundCue {play(.start,completed)}
            else {completed()}
        }
        session.onStopped={ [weak self] id in
            guard let self,self.recordingSession==id,self.session.state.session==id,
                  self.session.state.phase == .finishing || self.session.state.phase == .stopping else {return}
            self.recordingSession=nil
            self.restoreOutputVolume()
            if self.settings.current?.sounds ?? true {self.onSoundCue?(.stop,{})}
        }
        trigger.onToggle={ [weak self] revision in
            guard let self,revision==self.settings.revision,!self.settings.capturing else {return}
            self.session.toggle()
        }
        trigger.onKeyInput={ [weak settings] in settings?.receive($0) }
        trigger.onManualInput={ [weak session] in session?.send(.manualInput) }
        settings.restoreAtStartup()
    }
    func restoreOutputVolume() {
        pendingSilence=nil
        outputVolume?.restore()
    }
}
