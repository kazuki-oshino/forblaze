import Testing
import ForblazeTestSupport
import ForblazeCore
import ForblazeApplication
@testable import ForblazeMacOS
@MainActor final class FakeSpeechBackend:SpeechBackend {
    var calls:[String]=[]
    var resourceSnapshot:SpeechResourceSnapshot?
    var onObservation:((SpeechObservation)->Void)?
    var failCapture=false
    var prepareGate:ControlledGate<Bool>?
    let preparing=ControlledGate<Bool>()
    let stream=AsyncThrowingStream<RecognitionResult,Error>.makeStream()
    var vocabularies:[RecognitionVocabulary]=[]
    func prepare(session:SessionID,farField:Bool,vocabulary:RecognitionVocabulary) async throws -> AsyncThrowingStream<RecognitionResult,Error> {vocabularies.append(vocabulary);calls.append("prepare");await preparing.send(true);if let prepareGate {_=await prepareGate.next()};return stream.stream}
    var captureSizes:[SpeechBufferSize]=[]
    var warmups:[Bool]=[]
    func maintainPreparation(enabled:Bool,farField:Bool) {warmups.append(enabled)}
    func startCapture(bufferSize:SpeechBufferSize) throws {captureSizes.append(bufferSize);calls.append("capture");if failCapture {throw SessionFailure.audioDevice}}
    func closeInput() {calls.append("close")}
    func stopCapture() async {calls.append("release")}
    func finalize() async throws {calls.append("finalize");stream.continuation.finish()}
    func cancel() async {calls.append("cancel");stream.continuation.finish();resourceSnapshot = .init()}
}
@MainActor struct AppleSpeechTests {
    @Test func bufferSizeIsFixedBeforeAsynchronousPreparationAndWarmupRequiresOptIn() async throws {
        let backend=FakeSpeechBackend(),service=AppleSpeechService(backend:backend),gate=ControlledGate<Bool>()
        service.setPreparationAvailable(true)
        #expect(backend.warmups.last==false)
        service.prewarmEnabled=true
        #expect(backend.warmups.last==true)
        service.bufferSize = .small;backend.prepareGate=gate
        let task=Task {try await service.start(session:SessionID())}
        _=await backend.preparing.next()
        service.bufferSize = .standard
        await gate.send(true);_=try await task.value
        #expect(backend.captureSizes==[.small])
        service.setPreparationAvailable(false)
        #expect(backend.warmups.last==false)
        try await service.cancel()
        #expect(backend.warmups.last==false)
    }
    @Test func vocabularyIsPassedBeforeCaptureAndDoesNotLeakToTheNextSession() async throws {
        let backend=FakeSpeechBackend(),service=AppleSpeechService(backend:backend)
        _=try await service.start(session:SessionID(),vocabulary:RecognitionVocabulary(terms:["GraphQL"]))
        #expect(backend.vocabularies.last?.terms==["GraphQL"])
        #expect(backend.calls.prefix(2)==["prepare","capture"])
        try await service.cancel()
        _=try await service.start(session:SessionID())
        #expect(backend.vocabularies.last?.terms==[])
        try await service.cancel()
    }
    @Test func forwardsResourceCountsAndReportsReleaseAfterCancellation() async throws {
        let backend=FakeSpeechBackend(),service=AppleSpeechService(backend:backend)
        #expect(service.resourceSnapshot==nil)
        backend.resourceSnapshot = .init(rawAudioPeak:3,analyzerInputPeak:2,recognitionPeak:1,audioStreams:2,resultStreams:1,captureRunning:true)
        _=try await service.start(session:SessionID())
        #expect(service.resourceSnapshot==backend.resourceSnapshot)
        try await service.cancel()
        #expect(service.resourceSnapshot == .init())
    }

    @Test func rawRangesAndFailureStageAreRetainedWithoutTextAndBounded() async throws {
        let backend=FakeSpeechBackend(),service=AppleSpeechService(backend:backend)
        _=try await service.start(session:SessionID())
        for number in 0..<100 {backend.onObservation?(.init(.accepted,range:.init(0,Double(number+1)),isFinal:false))}
        backend.onObservation?(.init(.rejectedRange,range:.init(0.8,100),isFinal:true))
        #expect(service.observations.count==64)
        #expect(service.observations.last?.kind == .rejectedRange && service.observations.last?.isFinal==true)
        #expect(service.observations.last?.range == .init(0.8,100))
        try await service.cancel()
        _=try await service.start(session:SessionID())
        #expect(service.observations.isEmpty)
        backend.onObservation?(.init(.resultsFailed,errorCode:42))
        #expect(service.observations.last?.errorCode==42)
        try await service.cancel()
    }

    @Test func capturesAfterPreparationAndReleasesBeforeFinalization() async throws {
        let b=FakeSpeechBackend(),s=AppleSpeechService(backend:FakeSpeechBackend())
        let service=AppleSpeechService(backend:b)
        _=try await service.start(session:SessionID())
        #expect(b.calls == ["prepare","capture"])
        service.closeInput();await service.stopAudio();try await service.finalize();try await service.cancel()
        #expect(b.calls == ["prepare","capture","close","release","finalize","close","release","cancel"])
        try await s.cancel()
    }
    @Test func cancellationDuringModelPreparationCannotCapture() async throws {
        let b=FakeSpeechBackend(),gate=ControlledGate<Bool>();b.prepareGate=gate
        let service=AppleSpeechService(backend:b)
        let start=Task {try await service.start(session:SessionID())}
        _=await b.preparing.next();start.cancel();try await service.cancel();await gate.send(true)
        do {_=try await start.value;Issue.record("取消が必要")} catch {}
        #expect(!b.calls.contains("capture") && b.calls.contains("release"))
    }
    @Test func captureFailureAlwaysReleases() async {
        let b=FakeSpeechBackend();b.failCapture=true;let service=AppleSpeechService(backend:b)
        do { _=try await service.start(session:SessionID());Issue.record("起動失敗が必要") } catch {}
        #expect(b.calls.contains("release") && b.calls.contains("cancel"))
    }
}
