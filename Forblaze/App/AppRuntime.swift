import AppKit
import Foundation
import ForblazeCore
import ForblazeApplication
import ForblazeMacOS
@MainActor private final class AvailabilityGate {var value=Availability()}
/// 具体サービスを生成して接続する唯一の場所。
@MainActor final class AppRuntime {
    private let eligibility=AvailabilityGate()
    let permissions=ApplePermissionService()
    let trigger=CGEventTriggerMonitor()
    let speech:AppleSpeechService
    let clock=MonotonicSessionClock()
    let focus:AXFocusService
    let dictionary=FileDictionaryStore()
    let diagnostics=DiagnosticRecorder(log:BoundedDiagnosticLog())
    let input:LiveInputSession
    let composition:AppComposition
    let interruptions:InterruptionCoordinator
    let system:SystemInterruptionMonitor
    let loginItems=LoginItemCoordinator(service:SMLoginItemService())
    let settings:SettingsCoordinator
    let session:SessionCoordinator
    let model:DictationViewModel
    let presenter:StatusPresenter
    private let sounds=RecordingSoundPlayer()
    let settingsModel:SettingsViewModel
    let settingsWindow:SettingsWindowController
    private var settingsTask:Task<Void,Never>?
    private var refreshTask:Task<Void,Never>?
    private var quitTask:Task<Void,Never>?
    init() {
        focus=AXFocusService(diagnostics:diagnostics)
        speech=AppleSpeechService(clock:clock,diagnostics:diagnostics)
        let store=UserDefaultsSettingsStore(defaults:UserDefaults.standard)
        let jev=JevConfiguration.load(developmentFile:Bundle.main.object(forInfoDictionaryKey:"ForblazeEnvironmentFile") as? String)
        input=LiveInputSession(focus:focus,dictionary:dictionary,sink:CGEventTextSink(focus:focus,clock:clock),clock:clock,punctuationService:jev.map {JevPunctuationService(configuration:$0,log:JevUsageLog())},clipboard:SystemClipboardWriter(),diagnostics:diagnostics)
        let eligibility=self.eligibility
        let composition=AppComposition(speech:speech,clock:clock,trigger:trigger,store:store,canStart:{
            eligibility.value.canStart
        },input:input,diagnostics:diagnostics,outputVolume:SystemOutputVolumeControl())
        self.composition=composition;settings=composition.settings;session=composition.session;model=composition.model
        interruptions=InterruptionCoordinator(session:session,trigger:trigger)
        system=SystemInterruptionMonitor(permissions:permissions,clock:clock)
        model.forblazeMode=settings.current?.forblazeMode ?? false
        presenter=StatusPresenter(model:model,positionStore:UserDefaultsPanelPositionStore(defaults:.standard))
        trigger.preservesRecordingAtPoint={ [weak presenter] in presenter?.containsPanel(at:$0) ?? false }
        settingsModel=SettingsViewModel(session:session,settings:settings,issues:{ [weak input] in input?.dictionaryIssues ?? [] },observations:{ [weak speech] in speech?.observations ?? [] })
        settingsModel.punctuationAvailable=jev != nil
        settingsWindow=SettingsWindowController(model:settingsModel,dictionary:DictionaryEditorModel(store:dictionary))
        speech.farField=settings.current?.farField ?? true
        speech.prewarmEnabled=settings.current?.prewarmRecognition ?? false
        speech.bufferSize=settings.current?.speechBufferSize ?? .standard
        trigger.onDisabled={ [weak self] in self?.permissions.eventTap = .failed;self?.interruptions.handle(.tapDisabled) }
        interruptions.onResume={ [weak self] in self?.refresh(recovering:true) }
        system.onEvent={ [weak self] event in
            self?.speech.setPreparationAvailable(false)
            self?.presenter.stopEffects();self?.interruptions.handle(event)
        }
        system.onAvailability={ [weak self] value in
            self?.eligibility.value=value;self?.model.availability=value;self?.settingsModel.availability=value
            if !value.canStart {self?.speech.setPreparationAvailable(false)}
        }
        loginItems.onChange={ [weak self] in
            guard let self else {return}
            self.settingsModel.updateLogin(status:self.loginItems.status,error:self.loginItems.error)
        }
        settingsModel.onLoginChanged={ [weak loginItems] in loginItems?.setEnabled($0) }
        settingsModel.updateLogin(status:loginItems.status,error:nil)
        system.start()
        composition.onChange={ [weak self] in self?.settingsModel.synchronize();self?.presenter.refresh() }
        settings.onChange={ [weak self] in
            self?.settingsModel.synchronize()
            self?.speech.farField=self?.settings.current?.farField ?? true
            self?.speech.prewarmEnabled=self?.settings.current?.prewarmRecognition ?? false
            self?.speech.bufferSize=self?.settings.current?.speechBufferSize ?? .standard
            self?.model.forblazeMode=self?.settings.current?.forblazeMode ?? false
            self?.presenter.refresh()
        }
        speech.onLevel={ [weak model] in model?.level=$0 }
        speech.onProgress={ [weak model] in model?.modelProgress=$0 }
        composition.onSoundCue={ [weak sounds] cue,completion in
            guard let sounds else {completion();return}
            sounds.play(cue,completion:completion)
        }
        settingsModel.onPermission={ [weak self] in self?.refresh(request:$0) }
        settingsModel.onRefresh={ [weak self] in self?.refresh() }
        presenter.onSettings={ [weak self] in self?.openSettings() }
        presenter.onRefresh={ [weak self] in self?.refresh() }
        presenter.onPermission={ [weak self] in self?.refresh(request:$0) }
        presenter.onQuit={ [weak self] in self?.quit() }
        refresh()
    }
    func refresh(request:PermissionKind?=nil,recovering:Bool=false) {
        let previous=refreshTask
        previous?.cancel()
        refreshTask=Task { [self] in
            await previous?.value
            guard !Task.isCancelled else {return}
            if recovering {await session.awaitCleanup();trigger.stop();trigger.resetKeys()}
            if let request {await session.shutdown();_=await permissions.request(request)}
            do {try trigger.start();permissions.eventTap = .available}
            catch {permissions.eventTap = .failed}
            let availability=await permissions.snapshot()
            guard !Task.isCancelled else {return}
            eligibility.value=availability;model.availability=availability;settingsModel.availability=availability
            speech.setPreparationAvailable(availability.canStart)
            if availability.canStart,!settings.capturing,settings.error != .restore {settings.restoreAtStartup()}
            presenter.refresh()
            if composition.shouldPresentInitialSetup(for:availability) {openSettings()}
        }
    }
    func openSettings() {
        let previous=settingsTask
        settingsTask=Task { [self] in
            await previous?.value
            guard !Task.isCancelled else {return}
            await settingsModel.open()
            guard !Task.isCancelled else {return}
            settingsWindow.show()
        }
    }
    func quit() {NSApplication.shared.terminate(nil)}
    func prepareTermination() {
        guard quitTask==nil else {return}
        presenter.shutdown()
        speech.setPreparationAvailable(false)
        interruptions.handle(.quit)
        quitTask=Task { [self] in
            await system.stop();await loginItems.shutdown()
            settingsTask?.cancel();await settingsTask?.value
            refreshTask?.cancel();await refreshTask?.value
            await session.shutdown();composition.restoreOutputVolume()
            await speech.closePreparation();trigger.stop();await diagnostics.close();NSApplication.shared.reply(toApplicationShouldTerminate:true)
        }
    }
}
