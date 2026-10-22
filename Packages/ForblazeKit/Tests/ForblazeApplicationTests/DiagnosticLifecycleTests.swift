import Testing
import ForblazeCore
import ForblazeApplication
@MainActor struct DiagnosticLifecycleTests {
    @Test func targetDiagnosticsKeepTheReasonInsteadOfReportingEveryFailureAsFocusChange() async {
        let cases:[(TargetIssue,DiagnosticKind)]=[(.changed,.focusChanged),(.unavailable,.targetUnavailable),(.noneditable,.targetNoneditable),(.protected,.targetProtected)]
        for (issue,kind) in cases {
            let log=DiagnosticMemoryLog(),recorder=DiagnosticRecorder(log:log)
            let session=SessionCoordinator(speech:FakeSpeech(),clock:FakeClock(),diagnostics:recorder)
            session.toggle();let id=session.state.session!
            session.send(.failed(id,.target(issue)));await session.awaitCleanup();await recorder.close()
            let entries=await log.values()
            #expect(entries.filter{$0.kind==kind}.count==1)
            if issue != .changed {#expect(!entries.contains{$0.kind == .focusChanged})}
        }
    }

    @Test func pendingInputIsObservedAndReleasedOnManualOrFocusInterruption() async throws {
        for manual in [true,false] {
            let log=DiagnosticMemoryLog(),recorder=DiagnosticRecorder(log:log),speech=FakeSpeech(),focus=LiveFocus()
            let input=LiveInputSession(focus:focus,dictionary:LiveDictionary(),sink:QueueSink(),clock:QueueClock())
            let session=SessionCoordinator(speech:speech,clock:FakeClock(),input:input,diagnostics:recorder)
            let notices=AsyncStream<Void>.makeStream();var iterator=notices.stream.makeAsyncIterator()
            session.onRecognition={_ in
                // workerが動く前の同じMainActorターンで許可を取り消す。
                #expect(input.pendingCount==1)
                if manual {session.send(.manualInput)} else {focus.change()}
                notices.continuation.yield(())
            }
            session.toggle();await session.awaitPreparation();await recorder.flush()
            let id=try #require(session.state.session)
            speech.stream.continuation.yield(.init(session:id,segment:SegmentID(),range:.init(0,1),text:"本文を記録しない",isFinal:false))
            _=await iterator.next()
            await session.awaitCleanup();await recorder.close()
            let entries=await log.values()
            #expect(entries.filter{$0.kind == .inputPending}.map(\.count)==[0,1,0])
            #expect(entries.last?.kind == .idle && input.context==nil)
        }
    }

    @Test func resourcesAreLoggedOnChangeAndCleanupPrecedesIdle() async {
        let log=DiagnosticMemoryLog(),recorder=DiagnosticRecorder(log:log),speech=FakeSpeech()
        speech.resourceSnapshot = .init(rawAudioPeak:3,analyzerInputPeak:2,recognitionPeak:1,audioStreams:2,resultStreams:1,captureRunning:true)
        let session=SessionCoordinator(speech:speech,clock:FakeClock(),diagnostics:recorder)
        let notices=AsyncStream<Void>.makeStream();var iterator=notices.stream.makeAsyncIterator()
        session.onRecognition={_ in notices.continuation.yield(())}
        session.toggle();await session.awaitPreparation();await recorder.flush()
        let id=session.state.session!,segment=SegmentID()
        for _ in 0..<100 {
            speech.stream.continuation.yield(.init(session:id,segment:segment,range:.init(0,1),text:"保存しない本文",isFinal:false))
            _=await iterator.next()
        }
        session.send(.manualInput);await session.awaitCleanup();await recorder.close()
        let entries=await log.values()
        #expect(entries.filter{$0.kind == .rawAudioQueuePeak}.map(\.count)==[3])
        #expect(entries.filter{$0.kind == .audioStreams}.map(\.count)==[2,0])
        #expect(entries.filter{$0.kind == .resultStreams}.map(\.count)==[1,0])
        #expect(entries.filter{$0.kind == .captureRunning}.map(\.count)==[1,0])
        #expect(entries.last?.kind == .idle)
        #expect(entries.count<25)
    }

    @Test func firstResultAndStopTimingsUseClockAndNeverRecordText() async {
        let log=DiagnosticMemoryLog(),recorder=DiagnosticRecorder(log:log)
        let speech=FakeSpeech(),clock=FakeClock(),session=SessionCoordinator(speech:speech,clock:clock,diagnostics:recorder)
        let notices=AsyncStream<Void>.makeStream();var iterator=notices.stream.makeAsyncIterator()
        session.onRecognition={_ in notices.continuation.yield(())}
        session.toggle();await session.awaitPreparation()
        clock.time = .milliseconds(75)
        let id=session.state.session!,segment=SegmentID()
        speech.stream.continuation.yield(.init(session:id,segment:segment,range:.init(0,1),text:"診断へ保存しない本文",isFinal:false))
        _=await iterator.next()
        speech.stream.continuation.yield(.init(session:id,segment:segment,range:.init(0,1),text:"診断へ保存しない本文の更新",isFinal:false))
        _=await iterator.next()
        clock.time = .milliseconds(100)
        session.toggle();speech.stream.continuation.finish()
        await session.awaitFinalization();await session.awaitCleanup();await recorder.close()
        let entries=await log.values()
        #expect(entries.filter{$0.kind == .firstResult}.count==1)
        #expect(entries.first{$0.kind == .firstResult}?.milliseconds==75)
        #expect(entries.contains{$0.kind == .audioStopped} && entries.contains{$0.kind == .finalizationFinished})
        #expect(entries.last?.kind == .idle && session.state.lastError==nil)
    }
}
