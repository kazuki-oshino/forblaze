import Testing
import ForblazeCore
import ForblazeApplication
import ForblazeTestSupport

@MainActor final class AdvancingInputClock:SessionClock {
    var elapsed=Duration.zero
    var sleeps:[Duration]=[]
    func sleep(for duration:Duration) async throws {
        try Task.checkCancellation()
        sleeps.append(duration);elapsed += duration
    }
}

@MainActor final class TimedInputSink:TextSink {
    let clock:AdvancingInputClock
    let started=ControlledGate<Bool>()
    var times:[Duration]=[]
    var edits:[TextEdit]=[]
    var cost=Duration.zero
    init(clock:AdvancingInputClock) {self.clock=clock}
    func send(_ edit:TextEdit,context:InjectionContext,permit:@escaping @MainActor ()->Bool) async -> TextAcknowledgment {
        guard permit() else {return .init(deleted:0,inserted:"",completed:false)}
        times.append(clock.elapsed);edits.append(edit);clock.elapsed += cost
        await started.send(true)
        return .init(deleted:edit.deleteCount,inserted:edit.insertion,completed:true)
    }
}

@MainActor struct InputSchedulingTests {
    @Test func firstTextAndTextAfterAPauseHaveNoArtificialDelay() async {
        let clock=AdvancingInputClock(),sink=TimedInputSink(clock:clock)
        let queue=makeQueue(sink:sink,clock:clock),id=SegmentID()
        queue.enqueue(.init(id:id,range:.init(0,1),text:"最初",isFinal:false))
        _=await sink.started.next();await queue.drain()
        clock.elapsed = .seconds(1)
        queue.enqueue(.init(id:id,range:.init(0,2),text:"最初の追記",isFinal:false))
        _=await sink.started.next();await queue.drain()
        #expect(sink.times == [.zero,.seconds(1)])
        #expect(clock.sleeps.isEmpty)
        await queue.close()
    }

    @Test(arguments:[false,true]) func appendAndCorrectionHaveDifferentIntervals(editable:Bool) async {
        let clock=AdvancingInputClock(),sink=TimedInputSink(clock:clock)
        let queue=makeQueue(sink:sink,clock:clock),id=SegmentID()
        for text in ["あ","あい","あいう","あえ"] {
            if editable {queue.enqueue(EditableTextSnapshot(text:text))}
            else {queue.enqueue(.init(id:id,range:.init(0,1),text:text,isFinal:false))}
            _=await sink.started.next();await queue.drain()
        }
        #expect(sink.times == [.zero,.milliseconds(75),.milliseconds(150),.milliseconds(300)])
        #expect(sink.edits.last == .init(deleteCount:2,insertion:"え"))
        await queue.close()
    }

    @Test func unchangedResultsDoNotPostEventsButStillFinalizeTheSegment() async {
        let clock=AdvancingInputClock(),sink=TimedInputSink(clock:clock)
        let queue=makeQueue(sink:sink,clock:clock),id=SegmentID()
        queue.enqueue(.init(id:id,range:.init(0,1),text:"同じ",isFinal:false))
        _=await sink.started.next();await queue.drain()
        queue.enqueue(.init(id:id,range:.init(0,1),text:"同じ",isFinal:false));await queue.drain()
        queue.enqueue(.init(id:id,range:.init(0,1),text:"同じ",isFinal:true));await queue.drain()
        #expect(sink.edits.count==1)
        #expect(queue.planner.finalizedEnd==1)
        queue.enqueue(.init(id:SegmentID(),range:.init(1,2),text:"次",isFinal:true));await queue.drain()
        #expect(sink.edits.last == .init(deleteCount:0,insertion:"次"))
        await queue.close()
    }

    private func makeQueue(sink:any TextSink,clock:any SessionClock)->InjectionQueue {
        .init(sink:sink,clock:clock,context:.init(session:SessionID(),epoch:.init(1),target:.init(process:1,element:1)),allows:{true})
    }
}
