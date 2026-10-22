import Testing
import ForblazeCore
import ForblazeApplication
@MainActor final class LiveFocus:FocusService {
    var onChange:((FocusSnapshot)->Void)?
    var snapshot=FocusSnapshot(target:.init(id:.init(process:1,element:1),capability:.editable),epoch:.init(7))
    var changeOnSecondRead=false
    var secondReadTarget:FocusTarget?
    var notifyOnSecondRead=true
    var reads=0
    var preparations=0
    func prepare() async -> FocusSnapshot {preparations += 1;return await read()}
    func read() async -> FocusSnapshot {
        reads += 1
        if reads==2 {
            if changeOnSecondRead {change()}
            if let secondReadTarget {
                snapshot = .init(target:secondReadTarget,epoch:.init(8))
                if notifyOnSecondRead {onChange?(snapshot)}
            }
        }
        return snapshot
    }
    func change() {snapshot = .init(target:.init(id:.init(process:1,element:2),capability:.editable),epoch:.init(8));onChange?(snapshot)}
    func start() {}
    func stop() async {}
}
actor LiveDictionary:DictionaryStore {
    func load() -> DictionarySnapshot {.init(samples:"",personal:"誤字 => 正字")}
    func save(_ text:String) {}
}
@MainActor struct LiveInputTests {
    @Test func stoppingBeforeAnyTextWaitsForALateWholeSentence() async throws {
        let speech=FakeSpeech(),clock=FakeClock(),sink=QueueSink()
        let input=LiveInputSession(focus:LiveFocus(),dictionary:LiveDictionary(),sink:sink,clock:QueueClock())
        let session=SessionCoordinator(speech:speech,clock:clock,input:input)
        session.toggle();await session.awaitPreparation()
        let id=try #require(session.state.session)
        #expect(session.recognitionMetadata.isEmpty && sink.calls.isEmpty)
        session.toggle();_=await clock.sleeping.next();_=await speech.finalized.next()
        if await clock.advance(by:.milliseconds(1500)) {
            await session.awaitDeadline();await session.awaitCleanup()
        }
        #expect(session.state.phase == .finishing && session.state.permission == .open)
        speech.stream.continuation.yield(.init(session:id,segment:SegmentID(),range:.init(0,2),text:"明日は晴れます。",isFinal:true))
        speech.stream.continuation.finish()
        await session.awaitFinalization();await session.awaitCleanup()
        #expect(sink.calls == [.init(deleteCount:0,insertion:"明日は晴れます。")])
        #expect(session.state.phase == .idle && session.state.lastError==nil)
    }

    @Test func finalizationStillTimesOutAndRejectsTextAfterFiveSeconds() async throws {
        let speech=FakeSpeech(),clock=FakeClock(),sink=QueueSink()
        let log=DiagnosticMemoryLog(),recorder=DiagnosticRecorder(log:log)
        let input=LiveInputSession(focus:LiveFocus(),dictionary:LiveDictionary(),sink:sink,clock:QueueClock())
        let session=SessionCoordinator(speech:speech,clock:clock,input:input,diagnostics:recorder)
        session.toggle();await session.awaitPreparation();let id=try #require(session.state.session)
        session.toggle();_=await clock.sleeping.next()
        if await clock.advance(by:.milliseconds(4900)) {await session.awaitDeadline();await session.awaitCleanup()}
        #expect(session.state.phase == .finishing)
        #expect(await clock.advance(by:.milliseconds(100)))
        await session.awaitDeadline();await session.awaitCleanup()
        speech.stream.continuation.yield(.init(session:id,segment:SegmentID(),range:.init(0,2),text:"遅れて入力しない",isFinal:true))
        #expect(session.state.phase == .idle && session.state.lastError == .finalizationTimeout)
        #expect(sink.calls.isEmpty && input.context==nil && input.pendingCount==0)
        await recorder.close()
        let entries=await log.values()
        #expect(entries.filter{$0.kind.rawValue=="finalizationTimeout"}.count==1)
        #expect(entries.first{$0.kind.rawValue=="finalizationTimeout"}?.milliseconds==5000)
    }

    @Test func knownTargetChangeDoesNotBecomeAnAXLookupFailure() async {
        let speech=FakeSpeech(),focus=LiveFocus()
        let input=LiveInputSession(focus:focus,dictionary:LiveDictionary(),sink:QueueSink(),clock:QueueClock())
        let session=SessionCoordinator(speech:speech,clock:FakeClock(),input:input)
        session.toggle();await session.awaitPreparation()
        focus.onChange?(.init(target:.init(id:nil,capability:.unavailable),epoch:.init(8),invalidation:.changed))
        await session.awaitCleanup()
        #expect(session.state.lastError == .target(.changed))
    }

    @Test func rejectedTargetsKeepTheirReasonAndNeverStartRecording() async {
        let cases:[(TargetCapability,TargetIssue)]=[(.unavailable,.unavailable),(.noneditable,.noneditable),(.protected,.protected),(.editable,.unavailable)]
        for (capability,issue) in cases {
            let speech=FakeSpeech(),focus=LiveFocus(),sink=QueueSink()
            focus.snapshot = .init(target:.init(id:nil,capability:capability),epoch:.init(7))
            let input=LiveInputSession(focus:focus,dictionary:LiveDictionary(),sink:sink,clock:QueueClock())
            let session=SessionCoordinator(speech:speech,clock:FakeClock(),input:input)
            var starts=0,stops=0
            session.onStarted={_ in starts+=1};session.onStopped={_ in stops+=1}
            session.toggle();await session.awaitPreparation();await session.awaitCleanup()
            #expect(session.state.lastError == .target(issue) && session.state.failurePhase == .preparing)
            #expect(session.state.phase == .idle && session.state.permission == .closed)
            #expect(!speech.calls.contains("start") && sink.calls.isEmpty && starts==0 && stops==0)
            #expect(focus.preparations==1 && focus.reads==1)
            #expect(input.context==nil && input.pendingCount==0)
        }
    }

    @Test func targetLossAtFinalPreparationCheckPreservesReasonWithOrWithoutNotification() async {
        for notify in [true,false] {
            let speech=FakeSpeech(),focus=LiveFocus(),sink=QueueSink()
            focus.secondReadTarget = .init(id:nil,capability:.unavailable);focus.notifyOnSecondRead=notify
            let input=LiveInputSession(focus:focus,dictionary:LiveDictionary(),sink:sink,clock:QueueClock())
            let session=SessionCoordinator(speech:speech,clock:FakeClock(),input:input)
            var starts=0;session.onStarted={_ in starts+=1}
            session.toggle();await session.awaitPreparation();await session.awaitCleanup()
            #expect(session.state.lastError == .target(.unavailable) && session.state.failurePhase == .preparing)
            #expect(session.state.phase == .idle && sink.calls.isEmpty && starts==0)
        }
    }

    @Test func lossAfterRecordingClosesInputAndLateFocusCannotReplaceReason() async throws {
        for finishing in [false,true] {
            let speech=FakeSpeech(),focus=LiveFocus(),sink=QueueSink()
            let input=LiveInputSession(focus:focus,dictionary:LiveDictionary(),sink:sink,clock:QueueClock())
            let session=SessionCoordinator(speech:speech,clock:FakeClock(),input:input)
            session.toggle();await session.awaitPreparation();let id=try #require(session.state.session)
            if finishing {session.toggle()}
            focus.snapshot = .init(target:.init(id:nil,capability:.unavailable),epoch:.init(8))
            focus.onChange?(focus.snapshot)
            #expect(session.state.permission == .closed && speech.calls.last=="close")
            focus.change()
            input.receive(.init(session:id,segment:SegmentID(),range:.init(0,1),text:"追記しない",isFinal:true))
            await session.awaitCleanup()
            #expect(session.state.lastError == .target(.unavailable))
            #expect(session.state.failurePhase == (finishing ? .finishing:.listening))
            #expect(sink.calls.isEmpty && input.pendingCount==0 && input.context==nil)
        }
    }

    @Test func finalizationAndManualInputUseSamePermission() async throws {
        let speech=FakeSpeech(),focus=LiveFocus(),sink=QueueSink(),clock=QueueClock()
        let input=LiveInputSession(focus:focus,dictionary:LiveDictionary(),sink:sink,clock:clock)
        let c=SessionCoordinator(speech:speech,clock:FakeClock(),input:input)
        c.toggle();await c.awaitPreparation();try #require(c.state.phase == .listening)
        try #require(input.context?.epoch == .init(7))
        let id=try #require(c.state.session),segment=SegmentID()
        let notifications=AsyncStream<Void>.makeStream();var iterator=notifications.stream.makeAsyncIterator()
        c.onRecognition={_ in notifications.continuation.yield(())}
        speech.stream.continuation.yield(.init(session:id,segment:segment,range:.init(0,1),text:"誤字",isFinal:false))
        _=await iterator.next()
        _=await sink.started.next()
        c.toggle();speech.stream.continuation.yield(.init(session:id,segment:segment,range:.init(0,1),text:"誤字です",isFinal:true))
        speech.stream.continuation.finish();await c.awaitFinalization();await c.awaitCleanup()
        #expect(c.state.phase == .idle && c.state.lastError==nil)
        #expect(sink.calls.last==TextEdit(deleteCount:0,insertion:"です"))
        let nextSpeech=FakeSpeech(),nextInput=LiveInputSession(focus:focus,dictionary:LiveDictionary(),sink:sink,clock:clock)
        let next=SessionCoordinator(speech:nextSpeech,clock:FakeClock(),input:nextInput)
        next.toggle();await next.awaitPreparation();let nextID=try #require(next.state.session),count=sink.calls.count
        next.send(.manualInput)
        #expect(next.state.phase == .stopping && next.state.permission == .closed)
        #expect(nextSpeech.calls.last=="close" && nextInput.pendingCount==0)
        focus.change()
        nextSpeech.stream.continuation.yield(.init(session:nextID,segment:SegmentID(),range:.init(0,1),text:"後から増やさない",isFinal:true))
        await next.awaitCleanup()
        #expect(sink.calls.count==count && next.state.phase == .idle && next.state.lastError==nil)
        #expect(nextInput.context==nil && nextInput.pendingCount==0)
        #expect(nextSpeech.calls.contains("cancel") && !nextSpeech.calls.contains("finalize"))
    }
    @Test func finishingInterruptionRejectsLateResults() async throws {
        for kind in 0..<4 {
            let speech=FakeSpeech(),focus=LiveFocus(),sink=QueueSink()
            let input=LiveInputSession(focus:focus,dictionary:LiveDictionary(),sink:sink,clock:QueueClock())
            let c=SessionCoordinator(speech:speech,clock:FakeClock(),input:input)
            c.toggle();await c.awaitPreparation();let id=try #require(c.state.session)
            c.toggle();#expect(c.state.phase == .finishing)
            switch kind {
            case 0:c.send(.manualInput)
            case 1:focus.change()
            case 2:c.toggle()
            default:c.send(.timeout(id))
            }
            speech.stream.continuation.yield(.init(session:id,segment:SegmentID(),range:.init(0,1),text:"確定後も増やさない",isFinal:true))
            await c.awaitCleanup()
            #expect(c.state.phase == .idle && sink.calls.isEmpty)
            #expect(input.context==nil && input.pendingCount==0)
        }
    }
    @Test func preparationRechecksTargetAndOldCallbacksCannotPublish() async {
        let speech=FakeSpeech(),focus=LiveFocus(),sink=QueueSink();focus.changeOnSecondRead=true
        let input=LiveInputSession(focus:focus,dictionary:LiveDictionary(),sink:sink,clock:QueueClock())
        let c=SessionCoordinator(speech:speech,clock:FakeClock(),input:input)
        c.toggle();await c.awaitPreparation();await c.awaitCleanup()
        #expect(c.state.phase == .idle && c.state.lastError == .target(.changed) && sink.calls.isEmpty)
        #expect(speech.calls.contains("cancel"))
    }
}

@MainActor private final class AlternativeRecognizer:SpeechService {
    let output=AsyncThrowingStream<RecognitionResult,Error>.makeStream()
    var session:SessionID?
    func start(session:SessionID) async throws -> AsyncThrowingStream<RecognitionResult,Error> {self.session=session;return output.stream}
    func closeInput() {}
    func stopAudio() async {}
    func finalize() async throws {
        if let session {output.continuation.yield(.init(session:session,segment:SegmentID(),range:.init(0,1),text:"abc",isFinal:true))}
        output.continuation.finish()
    }
    func cancel() async throws {output.continuation.finish()}
}
@MainActor struct ReplaceableServicesTests {
    @Test func recognizerAndTransformCanChangeWithoutSinkOrLifecycleChanges() async {
        let sink=QueueSink(),speech=AlternativeRecognizer()
        let input=LiveInputSession(focus:LiveFocus(),dictionary:LiveDictionary(),sink:sink,clock:QueueClock(),transformFactory:{_ in TextTransform {$0.uppercased()}})
        let session=SessionCoordinator(speech:speech,clock:FakeClock(),input:input)
        session.toggle();await session.awaitPreparation();session.toggle()
        await session.awaitFinalization();await session.awaitCleanup()
        #expect(session.state.phase == .idle && session.state.lastError==nil)
        #expect(sink.calls==[TextEdit(deleteCount:0,insertion:"ABC")])
    }
}
