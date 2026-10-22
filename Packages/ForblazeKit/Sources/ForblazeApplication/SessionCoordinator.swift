import ForblazeCore
@MainActor public final class SessionCoordinator {
    private static let finalizationLimit:Duration = .seconds(5)
    public private(set) var state = SessionState()
    public private(set) var preview = ""
    public private(set) var recognitionMetadata:[RecognitionMetadata]=[]
    public var onChange: ((SessionState) -> Void)?
    public var onRecognition: ((RecognitionResult) -> Void)?
    public var onStarted: ((SessionID) -> Void)?
    public var onStopped: ((SessionID) -> Void)?
    private let speech: any SpeechService
    private let clock: any SessionClock
    private let canStart: () -> Bool
    private let diagnostics:DiagnosticRecorder?
    private var preparationTime=Duration.zero
    private var finishingTime=Duration.zero
    private var firstResultRecorded=false
    private var recordedResources:[DiagnosticKind:Int]=[:]
    private let input:LiveInputSession?
    private var preparingTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var finishingTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    public init(speech: any SpeechService, clock: any SessionClock, canStart: @escaping () -> Bool = { true },input:LiveInputSession?=nil,diagnostics:DiagnosticRecorder?=nil) {
        self.speech = speech;self.clock = clock;self.canStart = canStart;self.input=input;self.diagnostics=diagnostics
        input?.onTargetChanged={ [weak self] id,epoch,issue in
            guard let self,self.state.session==id else {return}
            self.send(.targetChanged(epoch,issue:issue))
        }
        input?.onFailure={ [weak self] id in self?.send(.injectionFailed(id)) }
        input?.onPreview={ [weak self] text in
            guard let self,self.state.permission == .open else {return}
            self.preview=text;self.onChange?(self.state)
        }
    }
    public func toggle() {
        guard state.phase != .idle || canStart() else { onChange?(state); return }
        send(.toggle(SessionID()))
    }
    public func send(_ event: SessionEvent) {
        let previous=state
        let effects = state.handle(event)
        input?.update(state)
        if previous != state {
            if state.phase == .idle || state.phase == .listening || state.phase == .finishing {recordResources()}
            recordState(previous:previous)
        }
        onChange?(state)
        for effect in effects {
            switch effect {
            case .prepare(let id):
                let dismissRepeatedRejection:Bool
                if case .target=previous.lastError {dismissRepeatedRejection=true}
                else {dismissRepeatedRejection=false}
                preview = "";recognitionMetadata=[];preparationTime=clock.elapsed;firstResultRecorded=false;recordedResources.removeAll(keepingCapacity:true)
                preparingTask = Task { [self] in
                    var inputPrepared=false
                    do {
                        _=try await input?.prepare(session:id)
                        inputPrepared=true
                        let stream = try await speech.start(session:id,vocabulary:input?.recognitionVocabulary ?? RecognitionVocabulary())
                        let epoch=try await input?.confirm() ?? TargetEpoch(1)
                        try Task.checkCancellation()
                        guard state.session == id, state.phase == .preparing else { return }
                        send(.prepared(id,epoch))
                        guard state.session == id, state.phase == .listening else {return}
                        onStarted?(id)
                        guard state.session == id, state.phase == .listening else {return}
                        resultsTask = Task { [self] in
                            do {
                                for try await result in stream {
                                    guard !Task.isCancelled, state.session == id,
                                          result.session == id, state.phase == .listening || state.phase == .finishing else { continue }
                                    if !firstResultRecorded {
                                        firstResultRecorded=true
                                        diagnostics?.submit(.firstResult,milliseconds:milliseconds(clock.elapsed-preparationTime))
                                    }
                                    recognitionMetadata.append(.init(range:result.range,isFinal:result.isFinal))
                                    if recognitionMetadata.count>RetentionLimits.metadataEntries {recognitionMetadata.removeFirst()}
                                    preview = String(result.text.suffix(RetentionLimits.previewCharacters))
                                    input?.receive(result)
                                    recordResources()
                                    onRecognition?(result); onChange?(state)
                                }
                                if !Task.isCancelled, state.session == id, state.phase == .listening {
                                    send(.failed(id, .recognition))
                                }
                            } catch {
                                if !Task.isCancelled, state.session == id, state.phase != .stopping { send(.failed(id, (error as? SessionFailure) ?? .recognition)) }
                            }
                        }
                    } catch {
                        if !Task.isCancelled, state.session == id, state.phase == .preparing {
                            let failure=(error as? SessionFailure) ?? .preparation
                            if dismissRepeatedRejection,!inputPrepared,case .target=failure {
                                // 案内中の再押下でまだ入力できなければ閉じる。録音開始後の失敗は隠さない。
                                send(.toggle(id))
                            } else {send(.failed(id,failure))}
                        }
                    }
                }
            case .finish(let id):
                finishingTime=clock.elapsed
                speech.closeInput()
                if previous.phase == .listening {onStopped?(id)}
                let subscription = resultsTask
                finishingTask = Task { [self] in
                    await speech.stopAudio()
                    recordResources()
                    diagnostics?.submit(.audioStopped,milliseconds:milliseconds(clock.elapsed-finishingTime))
                    do {
                        try Task.checkCancellation()
                        try await speech.finalize()
                        await subscription?.value
                        await input?.drain()
                        try Task.checkCancellation()
                        diagnostics?.submit(.finalizationFinished,milliseconds:milliseconds(clock.elapsed-finishingTime))
                        send(.finalized(id))
                    } catch {
                        if !Task.isCancelled { send(.failed(id, (error as? SessionFailure) ?? .recognition)) }
                    }
                }
                deadlineTask = Task { [self] in
                    do { try await clock.sleep(for: Self.finalizationLimit); try Task.checkCancellation(); send(.timeout(id)) }
                    catch { /* 所有者による取消。 */ }
                }
            case .cancel(let id):
                speech.closeInput()
                if previous.phase == .listening {onStopped?(id)}
                let preparation = preparingTask, subscription = resultsTask
                let finalization = finishingTask, deadline = deadlineTask
                preparation?.cancel(); subscription?.cancel(); finalization?.cancel(); deadline?.cancel()
                cleanupTask = Task { [self] in
                    do {
                        try await speech.cancel()
                        await input?.close()
                        await preparation?.value; await subscription?.value
                        await finalization?.value; await deadline?.value
                        preparingTask = nil; resultsTask = nil; finishingTask = nil; deadlineTask = nil
                        send(.cleaned(id))
                    } catch { send(.failed(id, .cleanup)) }
                }
            }
        }
    }
    private func recordResources() {
        guard diagnostics != nil else {return}
        var counts:[(DiagnosticKind,Int)]=[(.inputPending,input?.pendingCount ?? 0)]
        if let snapshot=speech.resourceSnapshot {
            counts += [(.rawAudioQueuePeak,snapshot.rawAudioPeak),(.analyzerInputQueuePeak,snapshot.analyzerInputPeak),
                       (.recognitionQueuePeak,snapshot.recognitionPeak),(.audioStreams,snapshot.audioStreams),
                       (.resultStreams,snapshot.resultStreams),(.captureRunning,snapshot.captureRunning ? 1 : 0)]
        }
        for (kind,count) in counts where recordedResources[kind] != count {
            recordedResources[kind]=count;diagnostics?.submit(kind,count:count)
        }
    }
    private func milliseconds(_ duration:Duration)->Double {
        let value=duration.components
        return max(0,Double(value.seconds)*1000+Double(value.attoseconds)/1e15)
    }
    private func recordState(previous:SessionState) {
        if state.permission == .suspended,previous.permission != .suspended {diagnostics?.submit(.suspended)}
        else if state.phase != previous.phase {
            let kind:DiagnosticKind
            switch state.phase {
            case .idle:kind = .idle
            case .preparing:kind = .preparing
            case .listening:kind = .listening
            case .finishing:kind = .finishing
            case .stopping:kind = .stopping
            }
            diagnostics?.submit(kind)
        }
        if let error=state.lastError,error != previous.lastError {
            switch error {
            case .permissionLost:diagnostics?.submit(.permissionLost)
            case .target(let issue):
                switch issue {
                case .changed:diagnostics?.submit(.focusChanged)
                case .unavailable:diagnostics?.submit(.targetUnavailable)
                case .noneditable:diagnostics?.submit(.targetNoneditable)
                case .protected:diagnostics?.submit(.targetProtected)
                }
            case .injection:diagnostics?.submit(.injectionFailed)
            case .audioDevice:diagnostics?.submit(.audioDevice)
            case .recognition:diagnostics?.submit(.recognitionFailed)
            case .finalizationTimeout:diagnostics?.submit(.finalizationTimeout,milliseconds:milliseconds(clock.elapsed-finishingTime))
            default:break
            }
        }
    }
    public func awaitPreparation() async { await preparingTask?.value }
    public func awaitFinalization() async { await finishingTask?.value }
    public func awaitDeadline() async { await deadlineTask?.value }
    public func awaitCleanup() async { await cleanupTask?.value }
    public func finishAndWait() async {
        if state.phase == .preparing || state.phase == .listening { toggle() }
        await finishingTask?.value
        await cleanupTask?.value
    }
    public func shutdown() async { send(.interrupt(.interrupted)); await cleanupTask?.value }
}
