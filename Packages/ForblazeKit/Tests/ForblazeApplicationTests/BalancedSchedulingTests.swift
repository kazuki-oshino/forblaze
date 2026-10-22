import Testing
import ForblazeCore
import ForblazeApplication

@MainActor struct BalancedSchedulingTests {
    @Test func fixedCorrectionReplayHalvesRewritesWithoutChangingFirstOrFinalText() async {
        var runs:[[TextEdit]]=[]
        for policy in [InputPresentationPolicy.direct,.balanced] {
            let sink=QueueSink(),clock=QueueClock(),id=SegmentID()
            let queue=InjectionQueue(sink:sink,clock:clock,context:.init(session:SessionID(),epoch:.init(1),target:.init(process:1,element:1)),allows:{true},policy:policy)
            func update(_ letter:String,_ time:Int,final:Bool=false) {
                clock.elapsed = .milliseconds(time)
                queue.enqueue(.init(id:id,range:.init(0,1),text:String(repeating:letter,count:40),isFinal:final))
            }
            update("あ",0);_=await sink.started.next();await queue.drain()
            #expect(clock.elapsed == .zero)
            update("い",100);let first=await clock.requests.next()
            update("う",140)
            if policy == .direct {
                first.finish();_=await sink.started.next();await queue.drain()
                #expect(clock.elapsed == .milliseconds(150))
                update("え",200);let second=await clock.requests.next()
                update("お",280);second.finish();_=await sink.started.next();await queue.drain()
                #expect(clock.elapsed == .milliseconds(300))
            } else {
                update("え",200);first.finish();let second=await clock.requests.next()
                update("お",280);second.finish();_=await clock.requests.next()
            }
            update("お",400,final:true);await queue.drain()
            #expect(queue.planner.finalizedEnd==1)
            #expect(clock.elapsed == .milliseconds(400))
            runs.append(sink.calls)
            await queue.close()
        }
        #expect(runs[0].reduce(0){$0+$1.deleteCount}==80)
        #expect(runs[1].reduce(0){$0+$1.deleteCount}==40)
        for edits in runs {
            #expect(edits.first?.insertion==String(repeating:"あ",count:40))
            #expect(edits.reduce(""){String($0.dropLast($1.deleteCount))+$1.insertion}==String(repeating:"お",count:40))
        }
    }
    private func queue(_ sink:QueueSink,_ clock:QueueClock)->InjectionQueue {
        .init(sink:sink,clock:clock,context:.init(session:SessionID(),epoch:.init(1),target:.init(process:1,element:1)),allows:{true},policy:.balanced)
    }
    @Test func changingCorrectionsShareOneMaximumDeadlineAndRepeatedTextDoesNotExtendStability() async {
        let sink=QueueSink(),clock=QueueClock(),queue=queue(sink,clock),id=SegmentID()
        queue.enqueue(.init(id:id,range:.init(0,1),text:"あ",isFinal:false));_=await sink.started.next();await queue.drain()
        clock.elapsed = .milliseconds(100)
        queue.enqueue(.init(id:id,range:.init(0,1),text:"い",isFinal:false))
        let first=await clock.requests.next()
        clock.elapsed = .milliseconds(200)
        queue.enqueue(.init(id:id,range:.init(0,1),text:"う",isFinal:false))
        first.finish()
        let second=await clock.requests.next()
        clock.elapsed = .milliseconds(300)
        queue.enqueue(.init(id:id,range:.init(0,1),text:"え",isFinal:false))
        second.finish()
        let third=await clock.requests.next()
        clock.elapsed = .milliseconds(390)
        queue.enqueue(.init(id:id,range:.init(0,1),text:"お",isFinal:false))
        third.finish();_=await sink.started.next();await queue.drain()
        #expect(clock.elapsed == .milliseconds(400))
        #expect(sink.calls.count==2 && sink.calls.last?.insertion=="お")
        await queue.close()
    }
    @Test func anAppendOrFinalCanWakeACorrectionWaitWithoutSealingPunctuationEditing() async {
        for final in [false,true] {
            let sink=QueueSink(),clock=QueueClock(),queue=queue(sink,clock)
            queue.enqueue(EditableTextSnapshot(text:"最初"));_=await sink.started.next();await queue.drain()
            clock.elapsed = .milliseconds(100)
            queue.enqueue(EditableTextSnapshot(text:"訂正"))
            _=await clock.requests.next()
            queue.enqueue(EditableTextSnapshot(text:final ? "確定":"最初の追記",isRecognitionFinal:final))
            _=await sink.started.next();await queue.drain()
            #expect(clock.elapsed == .milliseconds(100))
            #expect(!queue.editablePlanner.closed)
            #expect(sink.calls.last?.insertion == (final ? "確定":"の追記"))
            await queue.close()
        }
    }
    @Test func identicalNotificationsDoNotRestartTheStabilityClock() async {
        let sink=QueueSink(),clock=QueueClock(),queue=queue(sink,clock),id=SegmentID()
        queue.enqueue(.init(id:id,range:.init(0,1),text:"あ",isFinal:false));_=await sink.started.next();await queue.drain()
        clock.elapsed = .milliseconds(100)
        queue.enqueue(.init(id:id,range:.init(0,1),text:"い",isFinal:false))
        let timer=await clock.requests.next()
        clock.elapsed = .milliseconds(210)
        queue.enqueue(.init(id:id,range:.init(0,1),text:"い",isFinal:false))
        timer.finish();_=await sink.started.next();await queue.drain()
        #expect(clock.elapsed == .milliseconds(220) && sink.calls.count==2)
        await queue.close()
    }
}
