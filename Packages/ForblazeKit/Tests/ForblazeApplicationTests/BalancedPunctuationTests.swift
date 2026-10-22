import Testing
import ForblazeCore
import ForblazeApplication

@MainActor struct BalancedPunctuationTests {
    @Test func expiredReplyCannotChangeAlreadyIssuedText() async {
        let service=PunctuationFake(),clock=ImmediatePunctuationClock(),sink=QueueSink()
        let queue=InjectionQueue(sink:sink,clock:clock,context:.init(session:SessionID(),epoch:.init(1),target:.init(process:1,element:1)),allows:{true})
        let live=LivePunctuationSession(service:service,clock:clock,queue:queue,allows:{true},policy:.balanced)
        let original="こんにちは。続きを話しています。"
        live.receive(.init(id:SegmentID(),range:.init(0,1),text:original,isFinal:true))
        _=await service.calls.next();await queue.drain()
        clock.elapsed = .seconds(2)
        await service.answers.send(.comma);await live.finish()
        #expect(sink.calls.count==1 && sink.calls.first?.insertion==original)
        await live.close();await queue.close()
    }
    @Test func appliedPunctuationDoesNotGetReversedWhenRightContextGrows() async {
        let service=PunctuationFake(),clock=ImmediatePunctuationClock(),sink=QueueSink()
        let queue=InjectionQueue(sink:sink,clock:clock,context:.init(session:SessionID(),epoch:.init(1),target:.init(process:1,element:1)),allows:{true})
        let live=LivePunctuationSession(service:service,clock:clock,queue:queue,allows:{true},policy:.balanced),id=SegmentID()
        live.receive(.init(id:id,range:.init(0,1),text:"こんにちは。続きを話しています",isFinal:false))
        _=await service.calls.next();await queue.drain()
        await service.answers.send(.comma)
        _=await sink.started.next() // 初回
        _=await sink.started.next() // 補正
        await queue.drain()
        live.receive(.init(id:id,range:.init(0,2),text:"こんにちは。続きを話していますがもう少しだけ長く説明します",isFinal:true))
        await live.finish()
        #expect(await service.count==1)
        let text=sink.calls.reduce("") {String($0.dropLast($1.deleteCount))+$1.insertion}
        #expect(text=="こんにちは、続きを話していますがもう少しだけ長く説明します")
        await live.close();await queue.close()
    }
}
