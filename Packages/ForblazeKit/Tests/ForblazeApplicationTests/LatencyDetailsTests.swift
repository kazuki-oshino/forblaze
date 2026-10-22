import Testing
import ForblazeCore
import ForblazeTestSupport
@testable import ForblazeApplication

@MainActor struct LatencyDetailsTests {
    @Test func latestUpdateGetsOnlyItsOverlapWithTheTimerAndKeepsTheOverrun() async throws {
        let log=DiagnosticMemoryLog(),diagnostics=DiagnosticRecorder(log:log),clock=QueueClock(),sink=QueueSink()
        let queue=InjectionQueue(sink:sink,clock:clock,context:context(),allows:{true},diagnostics:diagnostics),id=SegmentID()
        queue.enqueue(.init(id:id,range:.init(0,1),text:"a",isFinal:false),receivedAt:.zero)
        _=await sink.started.next();await queue.drain()
        clock.elapsed = .milliseconds(10)
        queue.enqueue(.init(id:id,range:.init(0,1),text:"ab",isFinal:false),receivedAt:.milliseconds(8))
        let timer=await clock.requests.next()
        clock.elapsed = .milliseconds(20)
        queue.enqueue(.init(id:id,range:.init(0,1),text:"abc",isFinal:false),receivedAt:.milliseconds(18),handoff:.milliseconds(2))
        clock.elapsed = .milliseconds(120);timer.finish()
        _=await sink.started.next();await queue.drain();await queue.close();await diagnostics.flush()
        let trace=try #require(await log.detailValues().first?.samples.first)
        #expect(trace.values[.scheduledWait]==55)
        #expect(trace.values[.timerOverrun]==45)
        #expect(trace.values[.worker]==0)
        #expect(trace.values[.transform]==2 && trace.values[.handoff]==2)
        #expect(trace.values[.total]==104)
    }
    @Test func detailTransportFlushesAndRejectsNewEntriesAfterClose() async {
        let log=DiagnosticMemoryLog(),diagnostics=DiagnosticRecorder(log:log)
        let details=LatencyDiagnostic(session:SessionID().value,stage:.speech,samples:[.init(sequence:0,values:[.interimP95:400])])
        diagnostics.submit(details);await diagnostics.close();diagnostics.submit(details)
        #expect(await log.detailValues().count==1)
    }
    @Test func previousPublicationWaitIsSeparateFromTheNextTimer() async throws {
        let log=DiagnosticMemoryLog(),diagnostics=DiagnosticRecorder(log:log),clock=QueueClock(),sink=QueueSink(),pause=ControlledGate<Bool>()
        sink.pause=pause
        let queue=InjectionQueue(sink:sink,clock:clock,context:context(),allows:{true},diagnostics:diagnostics),id=SegmentID()
        queue.enqueue(.init(id:id,range:.init(0,1),text:"a",isFinal:false),receivedAt:.zero)
        _=await sink.started.next()
        clock.elapsed = .milliseconds(20)
        queue.enqueue(.init(id:id,range:.init(0,1),text:"ab",isFinal:false),receivedAt:clock.elapsed)
        clock.elapsed = .milliseconds(100);sink.pause=nil;await pause.send(true)
        let timer=await clock.requests.next();timer.finish()
        _=await sink.started.next();await queue.drain();await queue.close();await diagnostics.flush()
        let trace=try #require(await log.detailValues().first?.samples.first)
        #expect(trace.values[.total]==155)
        #expect(trace.values[.previousIssue]==80 && trace.values[.scheduledWait]==75)
        #expect(trace.values[.worker]==0 && trace.values[.timerOverrun]==0)
    }
    @Test func cancelledTimerCountsOnlyElapsedWaitAndKeepsPartialSinkCosts() async throws {
        let log=DiagnosticMemoryLog(),diagnostics=DiagnosticRecorder(log:log),metrics=InputLatencyMetrics(diagnostics:diagnostics,session:SessionID())
        var timing=TextIssueTiming();timing.focus = .milliseconds(40);timing.eventPost = .milliseconds(15);timing.cooperativeYield = .milliseconds(5)
        metrics.record(enqueuedAt:.milliseconds(10),receivedAt:.milliseconds(8),handoff:nil,
                       startedAt:.milliseconds(30),finishedAt:.milliseconds(100),previousIssueEnd:.zero,
                       waitStart:.milliseconds(10),deadline:.milliseconds(150),waitEnd:.milliseconds(30),
                       deleted:2,inserted:3,completed:false,timing:timing,isFinal:true)
        metrics.flush();await diagnostics.flush()
        let trace=try #require(await log.detailValues().first?.samples.first)
        #expect(trace.values[.scheduledWait]==20 && trace.values[.timerOverrun]==0)
        #expect(trace.values[.focus]==40 && trace.values[.eventPost]==15 && trace.values[.cooperativeYield]==5 && trace.values[.sinkOther]==10)
        #expect(trace.values[.completed]==0 && trace.values[.deleted]==2 && trace.values[.inserted]==3)
        #expect(await log.values().first{$0.kind == .inputPublications}?.count==0)
    }
    @Test func slowDetailsKeepOnlyEightLargestEventsAndWindowsStayBounded() async throws {
        let log=DiagnosticMemoryLog(),diagnostics=DiagnosticRecorder(log:log),metrics=InputLatencyMetrics(diagnostics:diagnostics,session:SessionID())
        for index in 0..<600 {
            metrics.record(enqueuedAt:.zero,receivedAt:.zero,handoff:nil,startedAt:.zero,finishedAt:.milliseconds(100+index),
                           previousIssueEnd:nil,waitStart:nil,deadline:nil,waitEnd:nil,deleted:0,inserted:1,completed:true,timing:nil,isFinal:true)
        }
        metrics.flush();await diagnostics.flush()
        let samples=try #require(await log.detailValues().first?.samples)
        #expect(samples.count==8 && samples.first?.values[.total]==699 && samples.last?.values[.total]==692)
        var window=LatencyWindow()
        window.append(-1);window.append(.infinity)
        for index in 0..<600 {window.append(Double(index))}
        var fields:[LatencyField:Double]=[:]
        window.store(in:&fields,keys:(.interimP50,.interimP95,.interimMax,.interimCount))
        #expect(fields[.interimCount]==512 && fields[.interimP50]==343 && fields[.interimMax]==599)
    }
    private func context()->InjectionContext {.init(session:SessionID(),epoch:.init(1),target:.init(process:1,element:1))}
}
