import Testing
import ForblazeCore
import ForblazeApplication
import ForblazeTestSupport

actor PunctuationFake:PunctuationDecisionService {
    let calls=ControlledGate<[PunctuationCandidate]>()
    let answers=ControlledGate<PunctuationChoice?>()
    private(set) var count=0
    func decide(_ candidates:[PunctuationCandidate]) async throws -> [PunctuationDecision] {
        count+=1;await calls.send(candidates)
        guard let choice=await answers.next() else {throw CancellationError()}
        return candidates.map {.init(candidate:$0,choice:choice)}
    }
}
@MainActor final class ImmediatePunctuationClock:SessionClock {
    var elapsed=Duration.zero
    func sleep(for duration:Duration) async throws {await Task.yield();try Task.checkCancellation()}
}
@MainActor struct LivePunctuationTests {
    @Test func finalizationDeadlineClosesPermissionWhileModelIsStillPending() async throws {
        let service=PunctuationFake(),sink=QueueSink(),speech=FakeSpeech(),clock=FakeClock()
        let input=LiveInputSession(focus:LiveFocus(),dictionary:LiveDictionary(),sink:sink,clock:ImmediatePunctuationClock(),punctuationService:service)
        input.punctuationEnabled={true}
        let session=SessionCoordinator(speech:speech,clock:clock,input:input)
        session.toggle();await session.awaitPreparation()
        let id=try #require(session.state.session)
        input.receive(.init(session:id,segment:SegmentID(),range:.init(0,1),text:"こんにちは。高須クリニックです。",isFinal:true))
        _=await service.calls.next()
        session.toggle();_=await clock.sleeping.next();speech.stream.continuation.finish()
        #expect(await clock.advance(by:.seconds(5)))
        await session.awaitDeadline()
        #expect(session.state.permission == .closed)
        let count=sink.calls.count
        await service.answers.send(.comma);await session.awaitCleanup()
        #expect(session.state.lastError == .finalizationTimeout && session.state.phase == .idle)
        #expect(sink.calls.count==count)
    }
    @Test func lateReplyAfterManualInputCannotReachTheNextSession() async throws {
        let service=PunctuationFake(),sink=QueueSink(),speech=FakeSpeech()
        let input=LiveInputSession(focus:LiveFocus(),dictionary:LiveDictionary(),sink:sink,clock:ImmediatePunctuationClock(),punctuationService:service)
        input.punctuationEnabled={true}
        let session=SessionCoordinator(speech:speech,clock:FakeClock(),input:input)
        session.toggle();await session.awaitPreparation()
        let old=try #require(session.state.session)
        input.receive(.init(session:old,segment:SegmentID(),range:.init(0,1),text:"こんにちは。高須クリニックです。",isFinal:true))
        _=await service.calls.next()
        session.send(.manualInput)
        let count=sink.calls.count
        await service.answers.send(.comma);await session.awaitCleanup()
        #expect(sink.calls.count==count && session.state.phase == .idle)
        input.punctuationEnabled={false}
        let next=SessionCoordinator(speech:FakeSpeech(),clock:FakeClock(),input:input)
        next.toggle();await next.awaitPreparation()
        let newID=try #require(next.state.session)
        #expect(newID != old)
        input.receive(.init(session:old,segment:SegmentID(),range:.init(1,2),text:"追記しない",isFinal:true))
        #expect(sink.calls.count==count)
        input.receive(.init(session:newID,segment:SegmentID(),range:.init(0,1),text:"新しい入力",isFinal:true))
        await input.drain()
        #expect(sink.calls.last==TextEdit(deleteCount:0,insertion:"新しい入力"))
        #expect(await service.count==1)
        await next.shutdown()
    }
    @Test func candidateOlderThanEightSecondsIsNotSent() async {
        let service=PunctuationFake(),sink=QueueSink(),clock=ImmediatePunctuationClock()
        let queue=InjectionQueue(sink:sink,clock:clock,context:.init(session:SessionID(),epoch:.init(1),target:.init(process:1,element:1)),allows:{true})
        let live=LivePunctuationSession(service:service,clock:clock,queue:queue,allows:{true})
        live.receive(.init(id:SegmentID(),range:.init(0,1),text:"こんにちは。",isFinal:true))
        clock.elapsed = .seconds(9)
        live.receive(.init(id:SegmentID(),range:.init(1,2),text:"高須クリニックです。",isFinal:true))
        await live.finish()
        #expect(await service.count==0)
        #expect(text(sink)=="こんにちは。高須クリニックです。")
        await live.close();await queue.close()
    }
    @Test func recognitionIsTypedBeforeTheModelResponds() async {
        let service=PunctuationFake(),(live,queue,sink)=setup(service)
        live.receive(.init(id:SegmentID(),range:.init(0,1),text:"こんにちは。高須クリニックです。",isFinal:true))
        _=await service.calls.next();await queue.drain()
        #expect(text(sink)=="こんにちは。高須クリニックです。")
        await service.answers.send(.comma);await live.finish()
        #expect(text(sink)=="こんにちは、高須クリニックです。")
        await live.close();await queue.close()
    }
    @Test func featureSwitchAndDictionaryAreConnectedToProductionInputPath() async throws {
        for enabled in [false,true] {
            let service=PunctuationFake(),sink=QueueSink()
            let input=LiveInputSession(focus:LiveFocus(),dictionary:LiveDictionary(),sink:sink,clock:ImmediatePunctuationClock(),punctuationService:service)
            input.punctuationEnabled={enabled}
            let session=SessionCoordinator(speech:FakeSpeech(),clock:FakeClock(),input:input)
            session.toggle();await session.awaitPreparation()
            let id=try #require(session.state.session)
            input.receive(.init(session:id,segment:SegmentID(),range:.init(0,1),text:"誤字です。続きを話します。",isFinal:true))
            if enabled {
                let candidates=await service.calls.next()
                #expect(candidates.first?.left=="正字です")
                await service.answers.send(.comma)
            }
            await input.drain()
            #expect(text(sink)==(enabled ? "正字です、続きを話します。":"正字です。続きを話します。"))
            #expect(await service.count==(enabled ? 1:0))
            await session.shutdown()
        }
    }
    private func setup(_ service:PunctuationFake)->(LivePunctuationSession,InjectionQueue,QueueSink) {
        let sink=QueueSink(),clock=ImmediatePunctuationClock()
        let queue=InjectionQueue(sink:sink,clock:clock,context:.init(session:SessionID(),epoch:.init(1),target:.init(process:1,element:1)),allows:{true})
        return (LivePunctuationSession(service:service,clock:clock,queue:queue,allows:{true}),queue,sink)
    }
    private func text(_ sink:QueueSink)->String {
        sink.calls.reduce("") {String($0.dropLast($1.deleteCount))+$1.insertion}
    }
    @Test func correctsAcrossFinalSegmentsAndDoesNotResendSameContext() async throws {
        let model=PunctuationFake(),(live,queue,sink)=setup(model)
        live.receive(.init(id:SegmentID(),range:.init(0,1),text:"こんにちは。",isFinal:true))
        let id=SegmentID()
        live.receive(.init(id:id,range:.init(1,2),text:"高須クリニックです。",isFinal:false))
        let candidates=await model.calls.next()
        #expect(candidates.count==1)
        await model.answers.send(.comma)
        await live.finish()
        #expect(text(sink)=="こんにちは、高須クリニックです。")
        #expect(await model.count==1)
        await live.close();await queue.close()
    }
    @Test func staleResponseCannotRewriteRevisedWords() async {
        let model=PunctuationFake(),(live,queue,sink)=setup(model),id=SegmentID()
        live.receive(.init(id:id,range:.init(0,1),text:"こんにちは。高須クリニックです。",isFinal:false))
        _=await model.calls.next()
        live.receive(.init(id:id,range:.init(0,2),text:"こんにちは今日は雨です",isFinal:true))
        await model.answers.send(.comma);await live.finish()
        #expect(text(sink)=="こんにちは今日は雨です")
        #expect(await model.count==1)
        await live.close();await queue.close()
    }
    @Test func invalidationDiscardsAnUncooperativeLateResponse() async {
        let model=PunctuationFake(),(live,queue,sink)=setup(model)
        live.receive(.init(id:SegmentID(),range:.init(0,1),text:"こんにちは。高須クリニックです。",isFinal:true))
        _=await model.calls.next();await queue.drain()
        live.invalidate();queue.invalidate()
        let count=sink.calls.count
        await model.answers.send(.comma);await live.close();await queue.close()
        #expect(sink.calls.count==count)
    }
    @Test func networkFailureKeepsOriginalAndNoPunctuationMakesNoRequest() async {
        let model=PunctuationFake(),(live,queue,sink)=setup(model)
        live.receive(.init(id:SegmentID(),range:.init(0,1),text:"こんにちは。高須クリニックです。",isFinal:true))
        _=await model.calls.next();await model.answers.send(nil)
        await live.finish()
        #expect(text(sink)=="こんにちは。高須クリニックです。")
        #expect(await model.count==1)
        await live.close();await queue.close()
        let empty=PunctuationFake(),(plain,plainQueue,plainSink)=setup(empty)
        plain.receive(.init(id:SegmentID(),range:.init(0,1),text:"句読点なしの本文",isFinal:true))
        await plain.finish()
        #expect(text(plainSink)=="句読点なしの本文")
        #expect(await empty.count==0)
        await plain.close();await plainQueue.close()
    }
    @Test func compactionDoesNotDeletePreviouslyTypedText() async {
        let model=PunctuationFake(),(live,queue,sink)=setup(model)
        let first=String(repeating:"あ",count:800)
        live.receive(.init(id:SegmentID(),range:.init(0,1),text:first,isFinal:true))
        live.receive(.init(id:SegmentID(),range:.init(1,2),text:"次の区間",isFinal:true))
        await live.finish()
        #expect(text(sink)==first+"次の区間")
        #expect(await model.count==0)
        await live.close();await queue.close()
    }
}
