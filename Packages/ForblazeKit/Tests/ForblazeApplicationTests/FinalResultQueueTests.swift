import Testing
import ForblazeCore
import ForblazeApplication
import ForblazeTestSupport

@MainActor struct FinalResultQueueTests {
    @Test(arguments:0..<4) func normalStopAcceptsFinalBurstsAndInterruptionsStillRevokeInput(interruption:Int) async throws {
        let speech=FakeSpeech(),focus=LiveFocus(),sink=QueueSink(),pause=ControlledGate<Bool>()
        sink.pause=pause
        let input=LiveInputSession(focus:focus,dictionary:LiveDictionary(),sink:sink,clock:QueueClock())
        let session=SessionCoordinator(speech:speech,clock:FakeClock(),input:input)
        session.toggle();await session.awaitPreparation()
        let id=try #require(session.state.session),segment=SegmentID()
        input.receive(.init(session:id,segment:segment,range:.init(0,3),text:"最初の途中結果",isFinal:false))
        _=await sink.started.next()
        session.toggle()
        #expect(session.state.phase == .finishing && speech.calls.last=="close")
        input.receive(.init(session:id,segment:segment,range:.init(0,1),text:"確定",isFinal:true))
        input.receive(.init(session:id,segment:SegmentID(),range:.init(1,2),text:"した",isFinal:true))
        input.receive(.init(session:id,segment:SegmentID(),range:.init(2,3),text:"全文",isFinal:true))
        #expect(session.state.phase == .finishing && session.state.lastError==nil)
        switch interruption {
        case 1:session.send(.manualInput)
        case 2:focus.change()
        case 3:session.toggle()
        default:break
        }
        sink.pause=nil;await pause.send(true);speech.stream.continuation.finish()
        await session.awaitFinalization();await session.awaitCleanup()
        #expect(session.state.phase == .idle && input.pendingCount==0 && input.context==nil)
        if interruption==0 {#expect(rendered(sink)=="確定した全文" && session.state.lastError==nil)}
        else {
            #expect(sink.calls.count==1)
            #expect(session.state.lastError == (interruption==2 ? .target(.changed):nil))
        }
    }

    @Test func splitFinalsWaitBehindTheCurrentPublicationWithoutLosingText() async throws {
        let sink=QueueSink(),clock=QueueClock(),pause=ControlledGate<Bool>()
        sink.pause=pause
        let queue=makeQueue(sink:sink,clock:clock)
        var failed=false;queue.onFailure={failed=true}
        let session=SessionID();var segments=RecognitionSegments(session:session)
        // 実機ログの時間範囲と到着順。本文は合成文へ置き換える。
        let partialRange=AudioRange(0,9.84)
        guard case .update(let id)=segments.resolve(session:session,range:partialRange,isFinal:false) else {Issue.record("途中区間が必要");return}
        queue.enqueue(.init(id:id,range:partialRange,text:"先頭まつび残して誤字",isFinal:false))
        _=await sink.started.next()
        let finals:[(AudioRange,String)]=[(.init(2.16,6.87),"先頭"),(.init(6.87,7.32),"末尾"),(.init(7.32,8.76),"残して"),(.init(8.76,9.84),"正字")]
        for (range,text) in finals {
            guard case .update(let id)=segments.resolve(session:session,range:range,isFinal:true) else {Issue.record("確定区間が必要");return}
            queue.enqueue(.init(id:id,range:range,text:text,isFinal:true))
        }
        #expect(!failed && queue.pendingCount==4)
        sink.pause=nil;await pause.send(true);await queue.drain()
        #expect(!failed && rendered(sink)=="先頭末尾残して正字")
        #expect(queue.planner.finalizedEnd==9.84 && queue.pendingCount==0)
        #expect(clock.durations.isEmpty)
        await queue.close()
    }

    @Test func queuedFinalsKeepTheirOrderWhileOnlyTheNewestPartialIsRetained() async {
        let sink=QueueSink(),pause=ControlledGate<Bool>();sink.pause=pause
        let queue=makeQueue(sink:sink,clock:QueueClock()),tail=SegmentID()
        var failed=false;queue.onFailure={failed=true}
        queue.enqueue(.init(id:SegmentID(),range:.init(0,1),text:"甲",isFinal:true))
        _=await sink.started.next()
        queue.enqueue(.init(id:SegmentID(),range:.init(1,2),text:"乙",isFinal:true))
        queue.enqueue(.init(id:SegmentID(),range:.init(2,3),text:"丙",isFinal:true))
        for i in 0..<100 {queue.enqueue(.init(id:tail,range:.init(3,4),text:String(i),isFinal:false))}
        #expect(!failed && queue.pendingCount==3)
        queue.enqueue(.init(id:tail,range:.init(3,4),text:"丁",isFinal:true))
        sink.pause=nil;await pause.send(true);await queue.drain()
        #expect(!failed && rendered(sink)=="甲乙丙丁" && sink.calls.count==4)
        #expect(queue.planner.finalizedEnd==4)
        await queue.close()
    }

    @Test func revocationDiscardsEveryQueuedFinalWithoutReportingAnInputFailure() async {
        let sink=QueueSink(),pause=ControlledGate<Bool>();sink.pause=pause
        var allowed=true,failed=false
        let queue=makeQueue(sink:sink,clock:QueueClock(),allows:{allowed})
        queue.onFailure={failed=true}
        queue.enqueue(.init(id:SegmentID(),range:.init(0,1),text:"先頭",isFinal:true))
        _=await sink.started.next()
        for i in 1...3 {queue.enqueue(.init(id:SegmentID(),range:.init(Double(i),Double(i+1)),text:"追記",isFinal:true))}
        #expect(!failed && queue.pendingCount==3)
        allowed=false;queue.invalidate();await pause.send(true);await queue.close()
        #expect(!failed && queue.pendingCount==0 && sink.calls.count==1)
    }

    @Test func aDifferentSegmentCannotSkipAnUnfinalizedSegment() async {
        let queue=makeQueue(sink:QueueSink(),clock:QueueClock())
        var failed=false;queue.onFailure={failed=true}
        queue.enqueue(.init(id:SegmentID(),range:.init(0,1),text:"未確定",isFinal:false))
        queue.enqueue(.init(id:SegmentID(),range:.init(1,2),text:"別区間",isFinal:true))
        #expect(failed && queue.pendingCount==0)
        await queue.close()
    }

    @Test func finalBacklogIsBoundedAndOverflowStopsBeforePublishing() async {
        let sink=QueueSink(),queue=makeQueue(sink:sink,clock:QueueClock())
        var failed=false;queue.onFailure={failed=true}
        for i in 0..<32 {queue.enqueue(.init(id:SegmentID(),range:.init(Double(i),Double(i+1)),text:"確定",isFinal:true))}
        #expect(!failed && queue.pendingCount==32)
        queue.enqueue(.init(id:SegmentID(),range:.init(32,33),text:"上限超過",isFinal:true))
        #expect(failed && queue.pendingCount==0)
        await queue.close();#expect(sink.calls.isEmpty)
    }

    private func makeQueue(sink:any TextSink,clock:any SessionClock,allows:@escaping ()->Bool={true})->InjectionQueue {
        .init(sink:sink,clock:clock,context:.init(session:SessionID(),epoch:.init(1),target:.init(process:1,element:1)),allows:allows)
    }
    private func rendered(_ sink:QueueSink)->String {
        sink.calls.reduce("") {String($0.dropLast($1.deleteCount))+$1.insertion}
    }
}
