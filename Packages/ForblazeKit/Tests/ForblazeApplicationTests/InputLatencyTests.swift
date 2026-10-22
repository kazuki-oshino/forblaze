import Testing
import ForblazeCore
import ForblazeApplication

@MainActor private final class LocalizedAckSink:TextSink {
    func send(_ edit:TextEdit,context:InjectionContext,permit:@escaping @MainActor ()->Bool) async -> TextAcknowledgment {
        .init(deleted:edit.deleteCount,inserted:edit.insertion,completed:true,preservedSuffixCount:edit.localized?.preservedSuffix.count ?? 0)
    }
}

@MainActor struct InputLatencyTests {
    @Test func localizedAcknowledgmentPreservesPlannerAndClipboardWhileCountingOnlyActualEdits() async {
        let log=DiagnosticMemoryLog(),diagnostics=DiagnosticRecorder(log:log),clock=AdvancingInputClock(),sink=LocalizedAckSink()
        let queue=InjectionQueue(sink:sink,clock:clock,context:context(),allows:{true},diagnostics:diagnostics),id=SegmentID()
        var copied="";queue.onAcknowledgment={copied=String(copied.dropLast($0.deleted))+$0.inserted}
        let suffix=String(repeating:"あ",count:85)
        queue.enqueue(.init(id:id,range:.init(0,1),text:"、"+suffix,isFinal:false));await queue.drain()
        queue.enqueue(.init(id:id,range:.init(0,1),text:"。"+suffix,isFinal:true));await queue.drain()
        #expect(copied=="。"+suffix && queue.planner.finalizedEnd==1 && queue.planner.issued.isEmpty)
        await queue.close();await diagnostics.flush()
        let entries=await log.values()
        #expect(entries.first{$0.kind == .inputRewrittenCharacters}?.count==1)
        #expect(entries.first{$0.kind == .inputPreservedCharacters}?.count==85)
        #expect(entries.first{$0.kind == .inputLocalizedPublications}?.count==1)
    }
    @Test func coalescingMeasuresTheLatestResultAndDoesNotExtendTheWait() async {
        let log=DiagnosticMemoryLog(),diagnostics=DiagnosticRecorder(log:log),clock=QueueClock(),sink=QueueSink()
        let queue=InjectionQueue(sink:sink,clock:clock,context:context(),allows:{true},diagnostics:diagnostics),id=SegmentID()
        queue.enqueue(.init(id:id,range:.init(0,1),text:"a",isFinal:false),receivedAt:.zero)
        _=await sink.started.next();await queue.drain()
        clock.elapsed = .milliseconds(10)
        queue.enqueue(.init(id:id,range:.init(0,1),text:"ab",isFinal:false),receivedAt:.milliseconds(8))
        let timer=await clock.requests.next()
        clock.elapsed = .milliseconds(20)
        queue.enqueue(.init(id:id,range:.init(0,1),text:"abc",isFinal:false),receivedAt:.milliseconds(18))
        timer.finish();_=await sink.started.next();await queue.drain();await queue.close();await diagnostics.flush()
        let entries=await log.values()
        #expect(clock.elapsed == .milliseconds(75))
        #expect(sink.calls.last == .init(deleteCount:0,insertion:"bc"))
        #expect(entries.first{$0.kind.rawValue=="inputQueueWaitP95"}?.milliseconds==55)
        #expect(entries.first{$0.kind.rawValue=="recognitionToIssueP95"}?.milliseconds==57)
    }
    @Test func separatesLatestResultWaitAndIssuingCostAndFlushesOnce() async {
        let log=DiagnosticMemoryLog(),diagnostics=DiagnosticRecorder(log:log)
        let clock=AdvancingInputClock(),sink=TimedInputSink(clock:clock);sink.cost = .milliseconds(5)
        let queue=InjectionQueue(sink:sink,clock:clock,context:context(),allows:{true},diagnostics:diagnostics)
        let id=SegmentID()
        clock.elapsed = .milliseconds(10)
        queue.enqueue(.init(id:id,range:.init(0,1),text:"保存しない",isFinal:false),receivedAt:.zero)
        _=await sink.started.next();await queue.drain()
        clock.elapsed = .milliseconds(25)
        queue.enqueue(.init(id:id,range:.init(0,1),text:"保存しない本文",isFinal:false),receivedAt:.milliseconds(20))
        _=await sink.started.next();await queue.drain()
        queue.enqueue(.init(id:id,range:.init(0,1),text:"保存しない本文",isFinal:true));await queue.drain()
        await diagnostics.flush()
        #expect(await log.values().isEmpty)
        await queue.close();await queue.close();await diagnostics.flush()
        let entries=await log.values()
        #expect(entries.first{$0.kind.rawValue=="firstInputIssued"}?.milliseconds==15)
        #expect(entries.first{$0.kind.rawValue=="inputQueueWaitP95"}?.milliseconds==65)
        #expect(entries.first{$0.kind.rawValue=="inputIssueDurationP95"}?.milliseconds==5)
        #expect(entries.first{$0.kind.rawValue=="recognitionToIssueP95"}?.milliseconds==75)
        #expect(entries.first{$0.kind.rawValue=="recognitionToIssueP95"}?.count==2)
        #expect(entries.filter{$0.kind.rawValue=="inputPublications"}.map(\.count)==[2])
        #expect(entries.count<=15)
    }

    @Test func keepsABoundedRecentWindowButCountsAllPublications() async {
        let log=DiagnosticMemoryLog(),diagnostics=DiagnosticRecorder(log:log)
        let clock=AdvancingInputClock(),sink=TimedInputSink(clock:clock)
        let queue=InjectionQueue(sink:sink,clock:clock,context:context(),allows:{true},diagnostics:diagnostics)
        for index in 0..<600 {
            sink.cost = .milliseconds(index<88 ? 999:2)
            queue.enqueue(.init(id:SegmentID(),range:.init(Double(index),Double(index+1)),text:"文",isFinal:true),receivedAt:clock.elapsed)
            await queue.drain()
        }
        await queue.close();await diagnostics.flush()
        let entries=await log.values()
        #expect(entries.first{$0.kind.rawValue=="inputPublications"}?.count==600)
        #expect(entries.first{$0.kind.rawValue=="inputIssueDurationMax"}?.count==512)
        #expect(entries.first{$0.kind.rawValue=="inputIssueDurationMax"}?.milliseconds==2)
    }

    @Test func partialPublicationIsCountedWithoutReportingItAsCompletedLatency() async {
        let log=DiagnosticMemoryLog(),diagnostics=DiagnosticRecorder(log:log),sink=QueueSink();sink.partial=true
        let queue=InjectionQueue(sink:sink,clock:QueueClock(),context:context(),allows:{true},diagnostics:diagnostics)
        queue.enqueue(.init(id:SegmentID(),range:.init(0,1),text:"途中まで",isFinal:true),receivedAt:.zero)
        await queue.drain();await queue.close();await diagnostics.flush()
        let entries=await log.values()
        #expect(entries.first{$0.kind.rawValue=="inputPartialPublications"}?.count==1)
        #expect(!entries.contains{$0.kind.rawValue=="recognitionToIssueP95"})
        #expect(!entries.contains{$0.kind.rawValue=="firstInputIssued"})
    }

    @Test func liveInputConnectsRecognitionTimingIncludingPunctuationMode() async throws {
        for punctuation in [false,true] {
            let log=DiagnosticMemoryLog(),diagnostics=DiagnosticRecorder(log:log)
            let clock=AdvancingInputClock(),sink=TimedInputSink(clock:clock);sink.cost = .milliseconds(7)
            let input=LiveInputSession(focus:LiveFocus(),dictionary:LiveDictionary(),sink:sink,clock:clock,punctuationService:PunctuationFake(),diagnostics:diagnostics)
            input.punctuationEnabled={punctuation}
            let session=SessionCoordinator(speech:FakeSpeech(),clock:clock,input:input)
            session.toggle();await session.awaitPreparation()
            let id=try #require(session.state.session)
            clock.elapsed = .milliseconds(200)
            input.receive(.init(session:id,segment:SegmentID(),range:.init(0,1),text:"誤字です",isFinal:true,emittedAt:.milliseconds(70)))
            await input.drain();await session.shutdown();await diagnostics.flush()
            let entries=await log.values()
            #expect(entries.first{$0.kind.rawValue=="recognitionToIssueP95"}?.milliseconds==7)
            #expect(sink.edits.first?.insertion=="正字です")
            let trace=try #require(await log.detailValues().first?.samples.first)
            #expect(trace.values[.handoff]==130 && trace.values[.total]==137)
        }
    }

    private func context()->InjectionContext {.init(session:SessionID(),epoch:.init(1),target:.init(process:1,element:1))}
}
