import Foundation
import AVFoundation
import Speech
import CoreMedia
import Synchronization
import ForblazeCore
import ForblazeApplication
@MainActor final class NativeSpeechBackend:SpeechBackend {
    private struct Prepared {
        let module:DictationTranscriber
        let analyzer:SpeechAnalyzer
        let format:AVAudioFormat
    }
    private let preparation:SpeechPreparationController<Bool,Prepared>
    func maintainPreparation(enabled:Bool,farField:Bool) {
        guard enabled else {preparation.invalidate();return}
        preparation.request(key:farField) {
            let module=ApplePermissionService.module(farField:farField)
            // 未導入の資源を背景でダウンロードしたり、権限を要求したりしない。
            guard await AssetInventory.status(forModules:[module]) == .installed,
                  let format=await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:[module]) else {throw SessionFailure.preparation}
            try Task.checkCancellation()
            let analyzer=SpeechAnalyzer(modules:[module],options:.init(priority:.userInitiated,modelRetention:.lingering))
            do {
                try await analyzer.prepareToAnalyze(in:format)
                try Task.checkCancellation()
                return Prepared(module:module,analyzer:analyzer,format:format)
            } catch {await analyzer.cancelAndFinishNow();throw error}
        }
    }
    func closePreparation() async {await preparation.close()}
    private let clock:any SessionClock
    private let diagnostics:DiagnosticRecorder?
    private var latency=SpeechLatencyTracker()
    private var latencySession:SessionID?
    init(clock:any SessionClock=MonotonicSessionClock(),diagnostics:DiagnosticRecorder?=nil) {
        self.clock=clock;self.diagnostics=diagnostics
        preparation=SpeechPreparationController(release:{ @MainActor resource in await resource.analyzer.cancelAndFinishNow() })
    }
    var onObservation:((SpeechObservation)->Void)?
    var onLevel: ((Float) -> Void)?
    var onProgress: ((Double) -> Void)?
    private var progressTask:Task<Void,Never>?
    private let accepting=AudioGate()
    private var engine:AVAudioEngine?
    private var hasTap=false
    private var analyzer:SpeechAnalyzer?
    private var transcriber:DictationTranscriber?
    private var audioInput:AsyncStream<AnalyzerInput>.Continuation?
    private var samples:AsyncThrowingStream<AudioSamples,Error>.Continuation?
    private var resultOutput:AsyncThrowingStream<RecognitionResult,Error>.Continuation?
    private var conversionTask:Task<Void,Never>?
    private var resultsTask:Task<Void,Never>?
    private let rawPeak=StreamQueuePeak(capacity:32)
    private let inputPeak=StreamQueuePeak(capacity:32)
    private let outputPeak=StreamQueuePeak(capacity:32)
    var resourceSnapshot:SpeechResourceSnapshot? {
        .init(rawAudioPeak:rawPeak.value,analyzerInputPeak:inputPeak.value,recognitionPeak:outputPeak.value,
              audioStreams:(samples == nil ? 0 : 1)+(audioInput == nil ? 0 : 1),
              resultStreams:resultOutput == nil ? 0 : 1,captureRunning:engine?.isRunning == true)
    }
    private var active:SessionID?
    func prepare(session:SessionID,farField:Bool,vocabulary:RecognitionVocabulary) async throws -> AsyncThrowingStream<RecognitionResult,Error> {
        rawPeak.reset();inputPeak.reset();outputPeak.reset()
        latency=SpeechLatencyTracker();latencySession=session
        active=session
        let prepared=preparation.take(key:farField)
        let module=prepared?.module ?? ApplePermissionService.module(farField:farField);transcriber=module
        // takeした資源も、後続の準備失敗時には通常のcancelが解放する。
        self.analyzer=prepared?.analyzer
        func check() throws {try Task.checkCancellation();guard active==session else {throw CancellationError()}}
        guard await DictationTranscriber.supportedLocale(equivalentTo:Locale(identifier:"ja-JP")) != nil else {throw SessionFailure.preparation}
        try check()
        switch await AssetInventory.status(forModules:[module]) {
        case .unsupported:throw SessionFailure.preparation
        case .supported,.downloading:
            if let request=try await AssetInventory.assetInstallationRequest(supporting:[module]) {
                try check()
                onProgress?(0)
                progressTask=Task { [weak self] in
                    while !Task.isCancelled {
                        self?.onProgress?(request.progress.fractionCompleted)
                        do {try await ContinuousClock().sleep(for:.milliseconds(200))} catch {return}
                    }
                }
                try await request.downloadAndInstall()
                progressTask?.cancel();await progressTask?.value;progressTask=nil;onProgress?(1)
            }
        case .installed:break
        @unknown default:throw SessionFailure.preparation
        }
        try check()
        let format:AVAudioFormat
        if let prepared {format=prepared.format}
        else if let available=await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:[module]) {format=available}
        else {throw SessionFailure.audioDevice}
        try check()
        let worker=try AudioConversion(target:AudioFormatDescription(format))
        let input=AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy:.bufferingOldest(32));audioInput=input.continuation
        let raw=AsyncThrowingStream<AudioSamples,Error>.makeStream(bufferingPolicy:.bufferingOldest(32));samples=raw.continuation
        let output=AsyncThrowingStream<RecognitionResult,Error>.makeStream(bufferingPolicy:.bufferingNewest(32));resultOutput=output.continuation
        let analyzer=prepared?.analyzer ?? SpeechAnalyzer(modules:[module]);self.analyzer=analyzer
        let context=AnalysisContext()
        context.contextualStrings[.general]=vocabulary.terms
        try await analyzer.setContext(context)
        try check()
        resultsTask=Task { [self] in
            var segments=RecognitionSegments(session:session)
            do {
                for try await result in module.results {
                    let emittedAt=clock.elapsed,received=AudioHostClock.now
                    guard !Task.isCancelled,active==session else {return}
                    guard result.text.characters.count<=RetentionLimits.segmentCharacters else {throw SessionFailure.recognition}
                    let range=AudioRange(CMTimeGetSeconds(result.range.start),CMTimeGetSeconds(CMTimeRangeGetEnd(result.range)))
                    let segment:SegmentID
                    switch segments.resolve(session:session,range:range,isFinal:result.isFinal) {
                    case .duplicate:onObservation?(.init(.duplicate,range:range,isFinal:result.isFinal));continue
                    case .invalid:onObservation?(.init(.rejectedRange,range:range,isFinal:result.isFinal));throw SessionFailure.recognition
                    case .update(let id):segment=id;onObservation?(.init(.accepted,range:range,isFinal:result.isFinal))
                    }
                    if !result.text.characters.isEmpty {
                        let ranges=result.text.runs.compactMap {run -> CMTimeRange? in run.audioTimeRange}
                        let start=ranges.map {CMTimeGetSeconds($0.start)}.min()
                        let end=ranges.map {CMTimeGetSeconds(CMTimeRangeGetEnd($0))}.max()
                        latency.result(start:start,end:end,received:received,isFinal:result.isFinal)
                    }
                    let value=RecognitionResult(session:session,segment:segment,range:range,text:String(result.text.characters),isFinal:result.isFinal,emittedAt:emittedAt)
                    switch output.continuation.yield(value) {
                    case .enqueued(let remaining):outputPeak.observe(remainingCapacity:remaining)
                    case .dropped:
                        outputPeak.observe(remainingCapacity:0)
                        onObservation?(.init(.outputOverflow));output.continuation.finish(throwing:SessionFailure.recognition);return
                    case .terminated:break
                    @unknown default:break
                    }
                }
                onObservation?(.init(.resultsEnded));output.continuation.finish()
            } catch {
                if !(error is SessionFailure),!Task.isCancelled {onObservation?(.init(.resultsFailed,errorCode:(error as NSError).code))}
                output.continuation.finish(throwing:SessionFailure.recognition)
            }
        }
        conversionTask=Task { [weak self] in
            func send(_ converted:AnalyzerInput) throws {
                try Task.checkCancellation()
                switch input.continuation.yield(converted) {
                case .enqueued(let remaining):self?.inputPeak.observe(remainingCapacity:remaining)
                case .dropped:self?.inputPeak.observe(remainingCapacity:0);throw SessionFailure.audioDevice
                case .terminated:throw CancellationError()
                @unknown default:throw SessionFailure.audioDevice
                }
            }
            do {
                for try await frame in raw.stream {
                    try Task.checkCancellation()
                    let conversionStart=AudioHostClock.now
                    if let channel=frame.channels.first,!channel.isEmpty {
                        let level=(channel.reduce(Float(0)) {$0+$1*$1}/Float(channel.count)).squareRoot()
                        self?.onLevel?(level)
                    }
                    let converted=try await worker.convert(frame)
                    if let timing=frame.timing {
                        self?.latency.frame(captureStart:timing.captureStart,tapTime:timing.tapTime,duration:Double(frame.channels.first?.count ?? 0)/frame.sampleRate,conversionStart:conversionStart,conversionEnd:AudioHostClock.now,frameLength:frame.channels.first?.count,sampleRate:frame.sampleRate)
                    }
                    if let converted {try send(converted)}
                }
                try Task.checkCancellation()
                // noDataNowで保留された末尾も渡してから、認識器へ音声の終端を通知する。
                for converted in try await worker.finish() {try send(converted)}
                input.continuation.finish()
            } catch {
                if !Task.isCancelled {self?.onObservation?(.init(.conversionFailed,errorCode:(error as NSError).code))}
                input.continuation.finish();output.continuation.finish(throwing:SessionFailure.audioDevice)
            }
        }
        try await analyzer.start(inputSequence:input.stream)
        try check()
        return output.stream
    }
    func startCapture(bufferSize:SpeechBufferSize) throws {
        let engine=AVAudioEngine();self.engine=engine
        let node=engine.inputNode,format=node.outputFormat(forBus:0)
        guard format.sampleRate>0,format.channelCount>0,format.commonFormat == .pcmFormatFloat32,let samples else {throw SessionFailure.audioDevice}
        accepting.set(true)
        let gate=accepting
        node.installTap(onBus:0,bufferSize:AVAudioFrameCount(bufferSize.rawValue),format:format,block:AudioTapBridge.callback(gate:gate,samples:samples,peak:rawPeak))
        hasTap=true;engine.prepare();try engine.start()
    }
    func closeInput() {accepting.set(false)}
    func stopCapture() async {
        closeInput()
        if let engine {
            if hasTap {engine.inputNode.removeTap(onBus:0)}
            hasTap=false;engine.stop();engine.reset();self.engine=nil
        }
        samples?.finish();samples=nil
        await conversionTask?.value;conversionTask=nil
        audioInput?.finish();audioInput=nil
    }
    func finalize() async throws {
        do {try await analyzer?.finalizeAndFinishThroughEndOfInput()}
        catch {if !Task.isCancelled {onObservation?(.init(.finalizationFailed,errorCode:(error as NSError).code))};throw error}
        await resultsTask?.value
    }
    func cancel() async {
        active=nil;closeInput()
        progressTask?.cancel();await progressTask?.value;progressTask=nil
        conversionTask?.cancel();resultsTask?.cancel()
        samples?.finish();audioInput?.finish();resultOutput?.finish()
        await analyzer?.cancelAndFinishNow()
        await conversionTask?.value;await resultsTask?.value
        conversionTask=nil;resultsTask=nil;analyzer=nil;transcriber=nil;resultOutput=nil
        if let session=latencySession {
            diagnostics?.submit(LatencyDiagnostic(session:session.value,stage:.speech,samples:[.init(sequence:0,values:latency.values)]))
            latencySession=nil;latency=SpeechLatencyTracker()
        }
    }
}
