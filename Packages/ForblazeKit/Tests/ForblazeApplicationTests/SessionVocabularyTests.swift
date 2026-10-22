import Testing
import ForblazeCore
import ForblazeApplication

private actor VocabularyDictionary:DictionaryStore {
    var loads=0
    var content="# forblaze-hint-v1: GraphQL\nぐらふ => GraphQL"
    func load()->DictionarySnapshot {loads += 1;return .init(samples:"",personal:content)}
    func save(_ text:String) {content=text}
}
@MainActor private final class VocabularySpeech:SpeechService {
    var terms:[String]=[]
    private var continuation:AsyncThrowingStream<RecognitionResult,Error>.Continuation?
    func start(session:SessionID) async throws -> AsyncThrowingStream<RecognitionResult,Error> {try await start(session:session,vocabulary:.init())}
    func start(session:SessionID,vocabulary:RecognitionVocabulary) async throws -> AsyncThrowingStream<RecognitionResult,Error> {
        terms=vocabulary.terms
        let pair=AsyncThrowingStream<RecognitionResult,Error>.makeStream();continuation=pair.continuation
        return pair.stream
    }
    func closeInput() {}
    func stopAudio() async {}
    func finalize() async throws {continuation?.finish()}
    func cancel() async throws {continuation?.finish()}
}
@MainActor struct SessionVocabularyTests {
    @Test func recognitionAndReplacementShareOneDictionarySnapshotPerSession() async throws {
        let dictionary=VocabularyDictionary(),speech=VocabularySpeech(),sink=QueueSink()
        let input=LiveInputSession(focus:LiveFocus(),dictionary:dictionary,sink:sink,clock:QueueClock())
        let coordinator=SessionCoordinator(speech:speech,clock:FakeClock(),input:input)
        coordinator.toggle();await coordinator.awaitPreparation()
        #expect(speech.terms==["GraphQL"])
        #expect(await dictionary.loads==1)
        await dictionary.save("# forblaze-hint-v1: Swift")
        let session=try #require(coordinator.state.session)
        input.receive(.init(session:session,segment:SegmentID(),range:.init(0,1),text:"ぐらふ",isFinal:true))
        await input.drain()
        #expect(sink.calls.last?.insertion=="GraphQL")
        await coordinator.shutdown()
        #expect(input.recognitionVocabulary.terms.isEmpty)
        coordinator.toggle();await coordinator.awaitPreparation()
        #expect(speech.terms==["Swift"])
        #expect(await dictionary.loads==2)
        await coordinator.shutdown()
    }
}
