import Testing
import ForblazeCore
import ForblazeApplication
import ForblazeTestSupport
@MainActor final class QueueClock:SessionClock {
    let requests=ControlledGate<AsyncThrowingStream<Void,Error>.Continuation>()
    var elapsed=Duration.zero
    var durations:[Duration]=[]
    func sleep(for duration:Duration) async throws {
        durations.append(duration)
        let deadline=elapsed+duration
        let pair=AsyncThrowingStream<Void,Error>.makeStream()
        await requests.send(pair.continuation)
        try await withTaskCancellationHandler {
            for try await _ in pair.stream {break}
        } onCancel: {pair.continuation.finish(throwing:CancellationError())}
        try Task.checkCancellation()
        elapsed=max(elapsed,deadline)
    }
    func advance() async {let cont=await requests.next();cont.finish()}
}
@MainActor final class QueueSink:TextSink {
    var calls:[TextEdit]=[]
    var pause:ControlledGate<Bool>?
    var partial=false
    let started=ControlledGate<Bool>()
    func send(_ edit:TextEdit,context:InjectionContext,permit:@escaping @MainActor ()->Bool) async -> TextAcknowledgment {
        calls.append(edit);await started.send(true)
        if let pause {_=await pause.next()}
        guard permit() else {return .init(deleted:0,inserted:"",completed:false)}
        if partial {return .init(deleted:0,inserted:String(edit.insertion.prefix(1)),completed:false)}
        return .init(deleted:edit.deleteCount,inserted:edit.insertion,completed:true)
    }
}
@MainActor struct InjectionQueueTests {
    @Test func continuousUpdatesKeepOneDeadlineAndInterruptionCancelsIt() async {
        let sink=QueueSink(),clock=QueueClock();var allowed=true
        let queue=InjectionQueue(sink:sink,clock:clock,context:.init(session:SessionID(),epoch:.init(1),target:.init(process:1,element:1)),allows:{allowed}),id=SegmentID()
        queue.enqueue(.init(id:id,range:.init(0,1),text:"a",isFinal:false))
        _=await sink.started.next();await queue.drain()
        queue.enqueue(.init(id:id,range:.init(0,1),text:"ab",isFinal:false))
        _=await clock.requests.next()
        for count in 3...100 {queue.enqueue(.init(id:id,range:.init(0,1),text:String(repeating:"a",count:count),isFinal:false))}
        #expect(clock.durations == [.milliseconds(75)] && queue.pendingCount==1)
        allowed=false;queue.invalidate();await queue.close()
        #expect(sink.calls.count==1 && queue.pendingCount==0)
    }
    @Test func slowSinkCoalescesUpdatesAndStillPublishesTheFinal() async {
        let sink=QueueSink(),clock=QueueClock(),pause=ControlledGate<Bool>();sink.pause=pause
        let queue=InjectionQueue(sink:sink,clock:clock,context:.init(session:SessionID(),epoch:.init(1),target:.init(process:1,element:1)),allows:{true}),id=SegmentID()
        queue.enqueue(.init(id:id,range:.init(0,1),text:"a",isFinal:false));_=await sink.started.next()
        for count in 2...100 {queue.enqueue(.init(id:id,range:.init(0,1),text:String(repeating:"a",count:count),isFinal:false))}
        queue.enqueue(.init(id:id,range:.init(0,1),text:"最終結果",isFinal:true))
        #expect(queue.pendingCount==1)
        sink.pause=nil;await pause.send(true);await queue.drain()
        #expect(sink.calls==[.init(deleteCount:0,insertion:"a"),.init(deleteCount:1,insertion:"最終結果")])
        #expect(queue.planner.finalizedEnd==1 && clock.durations.isEmpty)
        await queue.close()
    }
    @Test func editablePrefixCanOnlyBeReleasedAfterTheSinkAcknowledgesIt() async {
        let sink=QueueSink(),clock=QueueClock(),pause=ControlledGate<Bool>();sink.pause=pause
        let q=InjectionQueue(sink:sink,clock:clock,context:.init(session:SessionID(),epoch:.init(1),target:.init(process:1,element:1)),allows:{true})
        q.enqueue(EditableTextSnapshot(text:"先頭と末尾"))
        _=await sink.started.next()
        #expect(!q.discardIssuedPrefix("先頭"))
        await pause.send(true);await q.drain()
        #expect(!q.discardIssuedPrefix("不一致"))
        #expect(q.discardIssuedPrefix("先頭"))
        sink.pause=nil
        q.enqueue(EditableTextSnapshot(text:"と新しい末尾",closesEditing:true));await q.drain()
        let combined=sink.calls.reduce("") {String($0.dropLast($1.deleteCount))+$1.insertion}
        #expect(combined=="先頭と新しい末尾")
        await q.close()
    }
    @Test func finalReplacesWaitingPartialAndIncompletePublicationSuspends() async throws {
        let sink=QueueSink(),clock=QueueClock();let q=InjectionQueue(sink:sink,clock:clock,context:.init(session:SessionID(),epoch:.init(1),target:.init(process:1,element:1)),allows:{true}),id=SegmentID()
        q.enqueue(.init(id:id,range:.init(0,1),text:"最初",isFinal:false))
        _=await sink.started.next();await q.drain()
        q.enqueue(.init(id:id,range:.init(0,1),text:"途中",isFinal:false))
        _=await clock.requests.next()
        q.enqueue(.init(id:id,range:.init(0,1),text:"確定",isFinal:true))
        await q.drain()
        #expect(sink.calls==[.init(deleteCount:0,insertion:"最初"),.init(deleteCount:2,insertion:"確定")])
        sink.partial=true;var failed=false;q.onFailure={failed=true}
        q.enqueue(.init(id:SegmentID(),range:.init(1,2),text:"次の区間",isFinal:true))
        await q.drain();#expect(failed && q.pendingCount==0)
        await q.close()
    }
    @Test func onlyLatestAndFinalAreIssued() async throws {
        let sink=QueueSink(),clock=QueueClock();let q=InjectionQueue(sink:sink,clock:clock,context:.init(session:SessionID(),epoch:.init(1),target:.init(process:1,element:1)),allows:{true}),id=SegmentID()
        for text in ["a","ab","abc"] {q.enqueue(.init(id:id,range:.init(0,1),text:text,isFinal:false))}
        try #require(q.pendingCount==1)
        _=await sink.started.next();await q.drain()
        #expect(sink.calls==[.init(deleteCount:0,insertion:"abc")])
        q.enqueue(.init(id:id,range:.init(0,1),text:"abcd",isFinal:false))
        q.enqueue(.init(id:id,range:.init(0,1),text:"終わり",isFinal:true))
        await q.drain();#expect(sink.calls.last==TextEdit(deleteCount:3,insertion:"終わり"))
        #expect(q.planner.finalizedEnd==1 && q.pendingCount==0)
        await q.close()
    }
    @Test func revocationDuringPublicationRejectsRemainingAndOldTimer() async throws {
        let sink=QueueSink(),clock=QueueClock(),pause=ControlledGate<Bool>();sink.pause=pause
        var allowed=true;let q=InjectionQueue(sink:sink,clock:clock,context:.init(session:SessionID(),epoch:.init(1),target:.init(process:1,element:1)),allows:{allowed})
        q.enqueue(.init(id:SegmentID(),range:.init(0,1),text:"a",isFinal:true))
        try #require(q.pendingCount==1)
        _=await sink.started.next();allowed=false;q.invalidate();await pause.send(true);await q.close()
        #expect(q.planner.issued.isEmpty && q.pendingCount==0)
        q.enqueue(.init(id:SegmentID(),range:.init(1,2),text:"拒否",isFinal:true));await q.drain()
        #expect(sink.calls.count==1)
    }
}
