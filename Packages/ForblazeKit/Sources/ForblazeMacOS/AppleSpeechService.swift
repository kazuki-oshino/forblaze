import ForblazeCore
import ForblazeApplication
@MainActor protocol SpeechBackend: AnyObject {
    var resourceSnapshot:SpeechResourceSnapshot? {get}
    var onObservation:((SpeechObservation)->Void)? {get set}
    var onLevel: ((Float) -> Void)? {get set}
    var onProgress: ((Double) -> Void)? {get set}
    func prepare(session:SessionID,farField:Bool,vocabulary:RecognitionVocabulary) async throws -> AsyncThrowingStream<RecognitionResult,Error>
    func startCapture(bufferSize:SpeechBufferSize) throws
    func maintainPreparation(enabled:Bool,farField:Bool)
    func closePreparation() async
    func closeInput()
    func stopCapture() async
    func finalize() async throws
    func cancel() async
}
@MainActor public final class AppleSpeechService: SpeechService {
    public private(set) var observations:[SpeechObservation]=[]
    public var resourceSnapshot:SpeechResourceSnapshot? {backend.resourceSnapshot}
    public var farField = true {didSet {maintainPreparation()}}
    public var prewarmEnabled=false {didSet {maintainPreparation()}}
    public var bufferSize=SpeechBufferSize.standard
    private var preparationAvailable=false
    public var onLevel: ((Float) -> Void)?
    public var onProgress: ((Double) -> Void)?
    private let backend: any SpeechBackend
    private var session: SessionID?
    public convenience init(clock:any SessionClock=MonotonicSessionClock(),diagnostics:DiagnosticRecorder?=nil) {
        self.init(backend:NativeSpeechBackend(clock:clock,diagnostics:diagnostics))
    }
    init(backend:any SpeechBackend) {
        self.backend=backend
        backend.onObservation={ [weak self] observation in
            guard let self else {return}
            self.observations.append(observation)
            if self.observations.count>RetentionLimits.metadataEntries {self.observations.removeFirst()}
        }
        backend.onLevel={ [weak self] in self?.onLevel?($0) }
        backend.onProgress={ [weak self] in self?.onProgress?($0) }
    }
    public func start(session:SessionID) async throws -> AsyncThrowingStream<RecognitionResult,Error> {
        try await start(session:session,vocabulary:RecognitionVocabulary())
    }
    public func start(session:SessionID,vocabulary:RecognitionVocabulary) async throws -> AsyncThrowingStream<RecognitionResult,Error> {
        self.session=session;observations=[]
        let bufferSize=self.bufferSize
        do {
            let stream = try await backend.prepare(session:session,farField:farField,vocabulary:vocabulary)
            try Task.checkCancellation()
            guard self.session == session else { throw CancellationError() }
            try backend.startCapture(bufferSize:bufferSize)
            return stream
        } catch {
            backend.closeInput();await backend.stopCapture();await backend.cancel()
            throw error
        }
    }
    public func closeInput() {backend.closeInput()}
    public func stopAudio() async {await backend.stopCapture()}
    public func finalize() async throws {try await backend.finalize()}
    public func cancel() async throws {
        backend.closeInput();await backend.stopCapture();await backend.cancel();session=nil
        maintainPreparation()
    }
    public func setPreparationAvailable(_ available:Bool) {preparationAvailable=available;maintainPreparation()}
    private func maintainPreparation() {
        guard session==nil else {
            if !preparationAvailable || !prewarmEnabled {backend.maintainPreparation(enabled:false,farField:farField)}
            return
        }
        backend.maintainPreparation(enabled:preparationAvailable && prewarmEnabled,farField:farField)
    }
    public func closePreparation() async {preparationAvailable=false;await backend.closePreparation()}
}

extension SpeechBackend {
    func maintainPreparation(enabled:Bool,farField:Bool) {}
    func closePreparation() async {}
    var resourceSnapshot:SpeechResourceSnapshot? {nil}
    var onObservation:((SpeechObservation)->Void)? {get {nil} set {}}
    var onLevel: ((Float) -> Void)? {get {nil} set {}}
    var onProgress: ((Double) -> Void)? {get {nil} set {}}
}
