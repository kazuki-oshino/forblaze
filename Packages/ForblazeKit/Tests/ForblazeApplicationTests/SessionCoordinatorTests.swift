import Testing
import Foundation
import ForblazeCore
import ForblazeApplication
import ForblazeTestSupport
@MainActor final class FakeSpeech: SpeechService {
    var calls:[String]=[]
    var resourceSnapshot:SpeechResourceSnapshot?
    var startGate: ControlledGate<Bool>?
    var finishGate: ControlledGate<Bool>?
    var cleanupFails=false
    let started=ControlledGate<Bool>()
    let finalized=ControlledGate<Bool>()
    var id:SessionID?
    let stream=AsyncThrowingStream<RecognitionResult,Error>.makeStream()
    func start(session:SessionID) async throws -> AsyncThrowingStream<RecognitionResult,Error> {
        calls.append("start");id=session;await started.send(true)
        if let startGate { _=await startGate.next() }
        try Task.checkCancellation();return stream.stream
    }
    func closeInput() { calls.append("close") }
    func stopAudio() async { calls.append("stopAudio") }
    func finalize() async throws { calls.append("finalize");if let finishGate { _=await finishGate.next() };try Task.checkCancellation();await finalized.send(true) }
    func cancel() async throws { calls.append("cancel");stream.continuation.finish();if cleanupFails { throw SessionFailure.cleanup };if let snapshot=resourceSnapshot {resourceSnapshot = .init(rawAudioPeak:snapshot.rawAudioPeak,analyzerInputPeak:snapshot.analyzerInputPeak,recognitionPeak:snapshot.recognitionPeak)} }
}
@MainActor final class FakeClock:SessionClock {
    var time=Duration.zero
    var elapsed:Duration {time}
    private var waiter:AsyncThrowingStream<Void,Error>.Continuation?
    private var wakeTime:Duration?
    let sleeping=ControlledGate<Bool>()
    func sleep(for duration:Duration) async throws {
        wakeTime=time+duration
        let pair=AsyncThrowingStream<Void,Error>.makeStream();waiter=pair.continuation
        await sleeping.send(true)
        try await withTaskCancellationHandler {
            for try await _ in pair.stream {break}
        } onCancel: {pair.continuation.finish(throwing:CancellationError())}
    }
    func fire() async {waiter?.finish();waiter=nil}
    func advance(by duration:Duration) async -> Bool {
        time+=duration
        guard let wakeTime,time>=wakeTime else {return false}
        await fire();return true
    }

}
@MainActor struct SessionCoordinatorTests {
    @Test func stopNotificationFollowsSynchronousAudioGateAndOnlyOnce() async {
        let speech=FakeSpeech(),session=SessionCoordinator(speech:speech,clock:FakeClock())
        var stopped:[SessionID]=[]
        session.onStopped={id in
            #expect(speech.calls.last == "close")
            #expect(session.state.phase == .finishing || session.state.phase == .stopping)
            stopped.append(id)
        }
        session.toggle();await session.awaitPreparation();let id=session.state.session!
        session.toggle();#expect(stopped == [id])
        session.send(.manualInput);session.toggle();await session.awaitCleanup()
        #expect(stopped == [id])
    }
    @Test func stopDuringPreparedNotificationCannotEmitLateStart() async {
        let session=SessionCoordinator(speech:FakeSpeech(),clock:FakeClock())
        var started=0;session.onStarted={_ in started+=1}
        session.onChange={state in if state.phase == .listening {session.send(.manualInput)}}
        session.toggle();await session.awaitPreparation();await session.awaitCleanup()
        #expect(started==0 && session.state.phase == .idle)
    }

    @Test func audioFailureFromRecognitionStreamKeepsItsClassification() async {
        let speech=FakeSpeech(),session=SessionCoordinator(speech:speech,clock:FakeClock())
        let notices=AsyncStream<Void>.makeStream();var iterator=notices.stream.makeAsyncIterator()
        session.onChange={state in if state.phase == .idle,state.lastError != nil {notices.continuation.yield(())}}
        session.toggle();await session.awaitPreparation()
        speech.stream.continuation.finish(throwing:SessionFailure.audioDevice)
        _=await iterator.next();await session.awaitCleanup()
        #expect(session.state.lastError == .audioDevice && session.state.permission == .closed)
        #expect(speech.calls.contains("close") && speech.calls.contains("cancel"))
    }

    @Test func canceledPreparationCannotRestart() async {
        let speech=FakeSpeech(),clock=FakeClock();let gate=ControlledGate<Bool>();speech.startGate=gate
        let c=SessionCoordinator(speech:speech,clock:clock);c.toggle()
        _=await speech.started.next()
        c.toggle();#expect(c.state.phase == .stopping)
        c.toggle();await gate.send(true);await c.awaitCleanup()
        #expect(c.state.phase == .idle)
        #expect(speech.calls.filter{$0=="start"}.count == 1)
        #expect(speech.calls.contains("cancel"))
    }
    @Test func finalizationWaitsForBothCompletions() async {
        let speech=FakeSpeech(),clock=FakeClock();let gate=ControlledGate<Bool>();speech.finishGate=gate
        let c=SessionCoordinator(speech:speech,clock:clock);c.toggle();await c.awaitPreparation()
        #expect(c.state.phase == .listening)
        c.toggle();#expect(c.state.phase == .finishing && speech.calls.last == "close")
        _=await clock.sleeping.next()
        speech.stream.continuation.finish()
        #expect(c.state.phase == .finishing)
        await gate.send(true);await c.awaitFinalization()
        await c.awaitCleanup();#expect(c.state.phase == .idle)
        #expect(speech.calls.firstIndex(of:"stopAudio")! < speech.calls.firstIndex(of:"finalize")!)
    }
    @Test func apiCompletionAloneDoesNotCloseResults() async {
        let speech=FakeSpeech(),clock=FakeClock();let c=SessionCoordinator(speech:speech,clock:clock)
        c.toggle();await c.awaitPreparation();c.toggle();_=await speech.finalized.next()
        #expect(c.state.phase == .finishing)
        speech.stream.continuation.finish();await c.awaitFinalization();await c.awaitCleanup()
        #expect(c.state.phase == .idle && c.state.lastError == nil)
    }
    @Test func timeoutClosesPermissionAndCleanupFailureBlocksStart() async {
        let speech=FakeSpeech(),clock=FakeClock();speech.cleanupFails=true
        let c=SessionCoordinator(speech:speech,clock:clock);c.toggle();await c.awaitPreparation();c.toggle()
        _=await clock.sleeping.next();await clock.fire()
        await c.awaitDeadline();await c.awaitCleanup()
        #expect(c.state.phase == .stopping && c.state.permission == .closed && c.state.lastError == .cleanup)
        c.toggle();#expect(speech.calls.filter{$0=="start"}.count == 1)
    }
}
