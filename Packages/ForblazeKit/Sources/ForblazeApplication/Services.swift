import Foundation
import ForblazeCore
public struct RecognitionResult: Sendable {
    public let session: SessionID
    public let segment: SegmentID
    public let range: AudioRange
    public let text: String
    public let isFinal: Bool
    /// 本番では入力セッションと共有するSessionClock上のSDK結果受信時刻。
    public let emittedAt:Duration?
    public init(session: SessionID, segment: SegmentID, range: AudioRange, text: String, isFinal: Bool,emittedAt:Duration?=nil) {
        self.session = session; self.segment = segment; self.range = range; self.text = text; self.isFinal = isFinal
        self.emittedAt=emittedAt
    }
}
@MainActor public protocol SpeechService: AnyObject {
    var resourceSnapshot:SpeechResourceSnapshot? {get}
    var onLevel: ((Float) -> Void)? { get set }
    var onProgress: ((Double) -> Void)? { get set }
    func start(session: SessionID) async throws -> AsyncThrowingStream<RecognitionResult, Error>
    func start(session:SessionID,vocabulary:RecognitionVocabulary) async throws -> AsyncThrowingStream<RecognitionResult,Error>
    /// 音声受付を同期的に閉じる。重いエンジン停止はstopAudioで行う。
    func closeInput()
    func stopAudio() async
    func finalize() async throws
    func cancel() async throws
}
@MainActor public protocol SessionClock: AnyObject {
    func sleep(for duration: Duration) async throws
    var elapsed:Duration {get}
}
@MainActor public final class MonotonicSessionClock: SessionClock {
    private let origin=ContinuousClock.now
    public init() {}
    public var elapsed:Duration {origin.duration(to:.now)}
    public func sleep(for duration: Duration) async throws { try await ContinuousClock().sleep(for: duration) }
}

public extension SpeechService {
    func start(session:SessionID,vocabulary:RecognitionVocabulary) async throws -> AsyncThrowingStream<RecognitionResult,Error> {
        try await start(session:session)
    }
    var resourceSnapshot:SpeechResourceSnapshot? {nil}
    var onLevel: ((Float) -> Void)? { get { nil } set {} }
    var onProgress: ((Double) -> Void)? { get { nil } set {} }
}

public extension SessionClock {var elapsed:Duration {.zero}}
