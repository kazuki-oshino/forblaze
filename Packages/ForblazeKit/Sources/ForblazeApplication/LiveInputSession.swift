import ForblazeCore
@MainActor public final class LiveInputSession {
    private let focus:any FocusService
    private let dictionary:any DictionaryStore
    private let sink:any TextSink
    private let clock:any SessionClock
    private let transformFactory:(DictionarySnapshot)->TextTransform
    private let punctuationService:(any PunctuationDecisionService)?
    private let clipboard:(any ClipboardWriter)?
    private let diagnostics:DiagnosticRecorder?
    private var clipboardText:String?
    private var punctuation:LivePunctuationSession?
    public var punctuationEnabled:()->Bool={false}
    public var copyToClipboardEnabled:()->Bool={false}
    public var balancedInputEnabled:()->Bool={false}
    public var onPreview:((String)->Void)?
    private var state=SessionState()
    public private(set) var context:InjectionContext?
    public private(set) var dictionaryIssues:[DictionaryIssue]=[]
    public private(set) var recognitionVocabulary=RecognitionVocabulary()
    public var onTargetChanged:((SessionID,TargetEpoch,TargetIssue)->Void)?
    public var onFailure:((SessionID)->Void)?
    private var transform=TextTransform {$0}
    private var queue:InjectionQueue?
    public var pendingCount:Int {queue?.pendingCount ?? 0}
    public init(focus:any FocusService,dictionary:any DictionaryStore,sink:any TextSink,clock:any SessionClock,transformFactory:@escaping (DictionarySnapshot)->TextTransform={TextTransform(dictionary:$0)},punctuationService:(any PunctuationDecisionService)?=nil,clipboard:(any ClipboardWriter)?=nil,diagnostics:DiagnosticRecorder?=nil) {
        self.focus=focus;self.dictionary=dictionary;self.sink=sink;self.clock=clock;self.transformFactory=transformFactory
        self.punctuationService=punctuationService
        self.clipboard=clipboard
        self.diagnostics=diagnostics
        focus.onChange={ [weak self] snapshot in
            guard let self,let context=self.context else {return}
            if snapshot.epoch != context.epoch || snapshot.target.id != context.target || !snapshot.target.permitsInput {
                self.punctuation?.invalidate();self.queue?.invalidate();self.onTargetChanged?(context.session,snapshot.epoch,snapshot.inputIssue ?? .changed)
            }
        }
    }
    public func update(_ state:SessionState) {
        self.state=state
        if state.permission != .open {punctuation?.invalidate();queue?.invalidate()}
    }
    public func prepare(session:SessionID) async throws -> TargetEpoch {
        await close();try Task.checkCancellation()
        let target=await focus.prepare();try Task.checkCancellation()
        if let issue=target.inputIssue {throw SessionFailure.target(issue)}
        guard let id=target.target.id else {throw SessionFailure.target(.unavailable)}
        let context=InjectionContext(session:session,epoch:target.epoch,target:id);self.context=context
        focus.start()
        let snapshot=try await dictionary.load();try Task.checkCancellation()
        guard self.context?.session==session else {throw CancellationError()}
        dictionaryIssues=snapshot.issues;transform=transformFactory(snapshot)
        recognitionVocabulary=snapshot.recognitionVocabulary
        clipboardText=copyToClipboardEnabled() && clipboard != nil ? "":nil
        let policy:InputPresentationPolicy=balancedInputEnabled() ? .balanced:.direct
        queue=InjectionQueue(sink:sink,clock:clock,context:context,allows:{ [weak self] in
            guard let self else {return false}
            return self.context?.session==session && self.state.allows(session,context.epoch)
        },diagnostics:diagnostics,policy:policy)
        queue?.onFailure={ [weak self] in self?.onFailure?(session) }
        queue?.onAcknowledgment={ [weak self] acknowledgment in
            guard let self, self.clipboardText != nil else {return}
            // 認識結果ではなく発行済みの差分を重ね、辞書・句読点補正と部分発行を含める。
            self.clipboardText?.removeLast(acknowledgment.deleted)
            self.clipboardText?.append(contentsOf:acknowledgment.inserted)
        }
        if punctuationEnabled(),let punctuationService,let queue {
            punctuation=LivePunctuationSession(service:punctuationService,clock:clock,queue:queue,allows:{ [weak self] in
                guard let self else {return false}
                return self.context?.session==session && self.state.allows(session,context.epoch)
            },policy:policy,diagnostics:diagnostics)
            punctuation?.onPreview={ [weak self] in self?.onPreview?($0) }
            punctuation?.onFailure={ [weak self] in self?.onFailure?(session) }
        }
        return context.epoch
    }
    public func confirm() async throws -> TargetEpoch {
        guard let context else {throw CancellationError()}
        let target=await focus.read();try Task.checkCancellation()
        if let issue=target.inputIssue {throw SessionFailure.target(issue)}
        guard target.epoch==context.epoch,target.target.id==context.target,target.target.permitsInput else {throw SessionFailure.target(.changed)}
        return target.epoch
    }
    public func receive(_ result:RecognitionResult) {
        guard let context,state.allows(result.session,context.epoch),result.session==context.session else {return}
        let receivedAt=clock.elapsed
        let handoff=result.emittedAt.flatMap {$0<=receivedAt ? receivedAt-$0:nil}
        let corrected:TransformedText?
        if punctuation != nil {corrected=transform.applyWithProtection(to:result.text,maximumCharacters:RetentionLimits.segmentCharacters)}
        else {corrected=transform.apply(to:result.text,maximumCharacters:RetentionLimits.segmentCharacters).map {TransformedText(text:$0)}}
        guard let corrected else {onFailure?(result.session);return}
        let value=SegmentText(id:result.segment,range:result.range,text:corrected.text,isFinal:result.isFinal,protectedPunctuation:corrected.protectedPunctuation)
        if let punctuation {punctuation.receive(value,receivedAt:receivedAt,handoff:handoff)} else {queue?.enqueue(value,receivedAt:receivedAt,handoff:handoff)}
    }
    public func drain() async {await punctuation?.finish();await queue?.drain()}
    public func close() async {
        recognitionVocabulary=RecognitionVocabulary()
        context=nil;punctuation?.invalidate()
        await queue?.close();await punctuation?.close();punctuation=nil;queue=nil;transform=TextTransform {$0}
        await focus.stop()
        let text=clipboardText;clipboardText=nil
        if let text,!text.isEmpty {clipboard?.write(text)}
    }
}
