import Testing
import ForblazeCore
import ForblazeApplication
import ForblazeTestSupport

@MainActor final class ClipboardFake:ClipboardWriter {
    var writes:[String]=[]
    func write(_ text:String) {writes.append(text)}
}

@MainActor private final class ClipboardInFlightSink:TextSink {
    let started=ControlledGate<Bool>()
    let release=ControlledGate<Bool>()
    func send(_ edit:TextEdit,context:InjectionContext,permit:@escaping @MainActor ()->Bool) async -> TextAcknowledgment {
        guard permit() else {return .init(deleted:0,inserted:"",completed:false)}
        // 発行した直後に入力先が変わり、遅れて応答を返す状況。
        await started.send(true);_=await release.next()
        return .init(deleted:0,inserted:String(edit.insertion.prefix(2)),completed:false)
    }
}

@MainActor struct ClipboardTests {
    @Test(arguments:[false,true])
    func copiesRevisedDictionaryTextAndEverySegmentOnlyAfterStopping(enabled:Bool) async throws {
        let clipboard=ClipboardFake(),speech=FakeSpeech()
        let input=LiveInputSession(focus:LiveFocus(),dictionary:LiveDictionary(),sink:QueueSink(),clock:QueueClock(),clipboard:clipboard)
        input.copyToClipboardEnabled={enabled}
        let session=SessionCoordinator(speech:speech,clock:FakeClock(),input:input)
        session.toggle();await session.awaitPreparation()
        let id=try #require(session.state.session),segment=SegmentID()
        input.receive(.init(session:id,segment:segment,range:.init(0,1),text:"誤字の途中",isFinal:false))
        await input.drain()
        input.receive(.init(session:id,segment:segment,range:.init(0,2),text:"誤字を直した👨‍👩‍👧。",isFinal:true))
        await input.drain()
        #expect(clipboard.writes.isEmpty)
        session.toggle();_=await speech.finalized.next()
        #expect(clipboard.writes.isEmpty)
        speech.stream.continuation.yield(.init(session:id,segment:SegmentID(),range:.init(2,3),text:"最後の文。",isFinal:true))
        speech.stream.continuation.finish()
        await session.awaitFinalization();await session.awaitCleanup()
        #expect(clipboard.writes == (enabled ? ["正字を直した👨‍👩‍👧。最後の文。"]:[]))
        await input.close();await session.shutdown()
        #expect(clipboard.writes.count == (enabled ? 1:0))
    }

    @Test func emptyFailedAndSubsequentSessionsNeverReusePreviousText() async throws {
        let clipboard=ClipboardFake(),focus=LiveFocus()
        let input=LiveInputSession(focus:focus,dictionary:LiveDictionary(),sink:QueueSink(),clock:QueueClock(),clipboard:clipboard)
        var enabled=true;input.copyToClipboardEnabled={enabled}
        for text in ["最初の回","","次の回","OFFの回"] {
            enabled=text != "OFFの回"
            let session=SessionCoordinator(speech:FakeSpeech(),clock:FakeClock(),input:input)
            session.toggle();await session.awaitPreparation()
            let id=try #require(session.state.session)
            if !text.isEmpty {
                input.receive(.init(session:id,segment:SegmentID(),range:.init(0,1),text:text,isFinal:true))
                await input.drain()
            }
            await session.shutdown()
        }
        focus.snapshot = .init(target:.init(id:nil,capability:.noneditable),epoch:.init(9))
        let failed=SessionCoordinator(speech:FakeSpeech(),clock:FakeClock(),input:input)
        failed.toggle();await failed.awaitPreparation();await failed.awaitCleanup()
        #expect(clipboard.writes == ["最初の回","次の回"])
    }

    @Test func partialInputCopiesOnlyAcknowledgedCharactersAfterSuspension() async throws {
        let clipboard=ClipboardFake(),sink=QueueSink();sink.partial=true
        let input=LiveInputSession(focus:LiveFocus(),dictionary:LiveDictionary(),sink:sink,clock:QueueClock(),clipboard:clipboard)
        input.copyToClipboardEnabled={true}
        let session=SessionCoordinator(speech:FakeSpeech(),clock:FakeClock(),input:input)
        session.toggle();await session.awaitPreparation();let id=try #require(session.state.session)
        input.receive(.init(session:id,segment:SegmentID(),range:.init(0,1),text:"一部だけ発行",isFinal:true))
        await input.drain()
        #expect(session.state.permission == .suspended && clipboard.writes.isEmpty)
        session.toggle();await session.awaitCleanup()
        #expect(clipboard.writes == ["一"])
    }

    @Test func waitsForPunctuationAndKeepsCompactedPrefix() async throws {
        let clipboard=ClipboardFake(),service=PunctuationFake(),speech=FakeSpeech(),sink=QueueSink()
        let input=LiveInputSession(focus:LiveFocus(),dictionary:LiveDictionary(),sink:sink,clock:ImmediatePunctuationClock(),punctuationService:service,clipboard:clipboard)
        input.copyToClipboardEnabled={true};input.punctuationEnabled={true}
        let session=SessionCoordinator(speech:speech,clock:FakeClock(),input:input)
        session.toggle();await session.awaitPreparation();let id=try #require(session.state.session)
        let prefix=String(repeating:"あ",count:800)
        input.receive(.init(session:id,segment:SegmentID(),range:.init(0,1),text:prefix,isFinal:true))
        _=await sink.started.next()
        input.receive(.init(session:id,segment:SegmentID(),range:.init(1,2),text:"こんにちは。高須クリニックです。",isFinal:true))
        _=await service.calls.next()
        session.toggle();_=await speech.finalized.next();speech.stream.continuation.finish()
        #expect(clipboard.writes.isEmpty)
        await service.answers.send(.comma)
        await session.awaitFinalization();await session.awaitCleanup()
        #expect(clipboard.writes == [prefix+"こんにちは、高須クリニックです。"])
    }

    @Test func targetChangeWaitsForTheInFlightAcknowledgmentBeforeCopying() async throws {
        let clipboard=ClipboardFake(),sink=ClipboardInFlightSink(),focus=LiveFocus()
        let input=LiveInputSession(focus:focus,dictionary:LiveDictionary(),sink:sink,clock:QueueClock(),clipboard:clipboard)
        input.copyToClipboardEnabled={true}
        let session=SessionCoordinator(speech:FakeSpeech(),clock:FakeClock(),input:input)
        session.toggle();await session.awaitPreparation();let id=try #require(session.state.session)
        input.receive(.init(session:id,segment:SegmentID(),range:.init(0,1),text:"発行済みと未発行",isFinal:true))
        _=await sink.started.next();focus.change()
        #expect(clipboard.writes.isEmpty)
        await sink.release.send(true);await session.awaitCleanup()
        #expect(clipboard.writes == ["発行"])
    }

    @Test func timeoutCopiesIssuedTextAndRejectsLateResults() async throws {
        let clipboard=ClipboardFake(),speech=FakeSpeech(),clock=FakeClock()
        let input=LiveInputSession(focus:LiveFocus(),dictionary:LiveDictionary(),sink:QueueSink(),clock:QueueClock(),clipboard:clipboard)
        input.copyToClipboardEnabled={true}
        let session=SessionCoordinator(speech:speech,clock:clock,input:input)
        session.toggle();await session.awaitPreparation();let id=try #require(session.state.session)
        input.receive(.init(session:id,segment:SegmentID(),range:.init(0,1),text:"入力済み",isFinal:true));await input.drain()
        session.toggle();_=await clock.sleeping.next()
        #expect(await clock.advance(by:.seconds(5)))
        await session.awaitDeadline();await session.awaitCleanup()
        input.receive(.init(session:id,segment:SegmentID(),range:.init(1,2),text:"遅れた結果",isFinal:true))
        await input.close()
        #expect(clipboard.writes == ["入力済み"])
    }
}
