import Testing
import ForblazeCore
import ForblazeApplication
@MainActor struct ApplicationRetentionTests {
    @Test func burstKeepsLatestAndCleanupDropsCurrentText() async {
        let sink=QueueSink()
        let actual=InjectionQueue(sink:sink,clock:QueueClock(),context:.init(session:SessionID(),epoch:.init(1),target:.init(process:1,element:1)),allows:{true})
        let id=SegmentID()
        for i in 0..<10000 {actual.enqueue(.init(id:id,range:.init(0,1),text:String(i),isFinal:false))}
        #expect(actual.pendingCount==1)
        await actual.drain();#expect(sink.calls==[.init(deleteCount:0,insertion:"9999")])
        await actual.close();#expect(actual.pendingCount==0 && actual.planner.issued.isEmpty)
    }
    @Test func recognitionPreviewAndMetadataRemainBounded() async throws {
        let speech=FakeSpeech(),session=SessionCoordinator(speech:speech,clock:FakeClock())
        session.toggle();await session.awaitPreparation();let id=try #require(session.state.session)
        let completed=AsyncStream<Void>.makeStream();var iterator=completed.stream.makeAsyncIterator(),received=0
        session.onRecognition={_ in received += 1;if received==1000 {completed.continuation.yield(())}}
        for i in 0..<1000 {
            speech.stream.continuation.yield(.init(session:id,segment:SegmentID(),range:.init(Double(i),Double(i+1)),text:String(repeating:"あ",count:500),isFinal:true))
        }
        _=await iterator.next()
        #expect(session.preview.count==RetentionLimits.previewCharacters)
        #expect(session.recognitionMetadata.count==RetentionLimits.metadataEntries)
        await session.shutdown()
    }
}
