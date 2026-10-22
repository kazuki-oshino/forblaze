import ForblazeCore

/// 音声区間の確定と、補正可能な末尾の確定を分離する。
@MainActor public final class LivePunctuationSession {
    private let service:any PunctuationDecisionService
    private let clock:any SessionClock
    private let queue:InjectionQueue
    private let allows:()->Bool
    private let policy:InputPresentationPolicy
    private let diagnostics:DiagnosticRecorder?
    private var settled:[Int:PunctuationCandidate]=[:]
    private var expired=Set<Int>()
    private var expiredCount=0
    private var appliedCount=0
    private var reported=false
    private var document=PunctuationDocument()
    private var debounce:Task<Void,Never>?
    private var request:Task<Void,Never>?
    private var compaction:Task<Void,Never>?
    private var generation=0
    private var closed=false
    private var finishing=false
    private var cooldownUntil=Duration.zero
    private var firstSeen:[Int:Duration]=[:]
    public var onPreview:((String)->Void)?
    public var onFailure:(()->Void)?
    public init(service:any PunctuationDecisionService,clock:any SessionClock,queue:InjectionQueue,allows:@escaping ()->Bool,policy:InputPresentationPolicy = .direct,diagnostics:DiagnosticRecorder?=nil) {
        self.service=service;self.clock=clock;self.queue=queue;self.allows=allows
        self.policy=policy;self.diagnostics=diagnostics
    }
    public func receive(_ value:SegmentText,receivedAt:Duration?=nil,handoff:Duration?=nil) {
        guard !closed,allows() else {return}
        guard document.receive(value) else {onFailure?();return}
        let offsets=document.punctuationOffsets
        firstSeen=firstSeen.filter {offsets.contains($0.key)}
        expired=expired.intersection(offsets)
        settled=settled.filter {offsets.contains($0.key) && document.stillContains($0.value)}
        for offset in offsets where firstSeen[offset]==nil {firstSeen[offset]=clock.elapsed}
        publish(recognitionFinal:value.isFinal,receivedAt:receivedAt,handoff:handoff);schedule();compact()
    }
    private func publish(final:Bool=false,recognitionFinal:Bool=false,receivedAt:Duration?=nil,handoff:Duration?=nil) {
        guard !closed,allows() else {return}
        let text=document.rendered
        onPreview?(String(text.suffix(RetentionLimits.previewCharacters)))
        queue.enqueue(EditableTextSnapshot(text:text,closesEditing:final,isRecognitionFinal:recognitionFinal),receivedAt:receivedAt,handoff:handoff)
    }
    private func schedule() {
        guard !closed,!finishing,request==nil,clock.elapsed>=cooldownUntil else {return}
        guard !pendingCandidates().isEmpty else {debounce?.cancel();debounce=nil;return}
        // 追記のたびにタイマーを延ばすと連続発話中に一度も判定できない。
        guard debounce==nil else {return}
        let revision=generation
        debounce=Task { [weak self] in
            guard let self else {return}
            do {try await clock.sleep(for:.milliseconds(350));try Task.checkCancellation()}
            catch {return}
            guard generation==revision,!closed,allows() else {return}
            debounce=nil;startRequest()
        }
    }
    private func startRequest() {
        guard !closed,allows(),request==nil,clock.elapsed>=cooldownUntil else {return}
        let candidates=Array(pendingCandidates().prefix(4))
        guard !candidates.isEmpty else {return}
        document.markAttempted(candidates)
        let revision=generation
        request=Task { [weak self] in
            guard let self else {return}
            do {
                let results=try await service.decide(candidates)
                try Task.checkCancellation()
                guard generation==revision,!closed,allows() else {return}
                for result in results where candidates.contains(result.candidate) && isFresh(result.candidate) {
                    if policy.settlesPunctuation,settled[result.candidate.offset] != nil {continue}
                    let before=document.rendered
                    document.accept(result.choice,for:result.candidate)
                    if document.rendered != before {
                        appliedCount=min(1_000_000,appliedCount+1)
                        if policy.settlesPunctuation {settled[result.candidate.offset]=result.candidate}
                    }
                }
                publish()
            } catch {
                // 通信失敗で音声入力を止めず、同じ候補の即時再送も行わない。
                if generation==revision,!closed {cooldownUntil=clock.elapsed + .seconds(10)}
            }
            guard generation==revision else {return}
            request=nil;schedule();compact()
        }
    }
    private func isFresh(_ candidate:PunctuationCandidate)->Bool {
        guard let seen=firstSeen[candidate.offset] else {return false}
        let fresh=clock.elapsed-seen<=policy.punctuationLifetime
        if !fresh,expired.insert(candidate.offset).inserted {expiredCount=min(1_000_000,expiredCount+1)}
        return fresh
    }
    private func pendingCandidates()->[PunctuationCandidate] {
        document.pendingCandidates(finalizing:finishing).filter {isFresh($0) && (!policy.settlesPunctuation || settled[$0.offset]==nil)}
    }
    private func compact() {
        guard !closed,compaction==nil,document.compactableCount>0 else {return}
        let revision=generation
        compaction=Task { [weak self] in
            guard let self else {return}
            await queue.drain()
            guard generation==revision,!closed,allows() else {return}
            let count=document.compactableCount
            let prefix=document.renderedPrefix(rawCount:count)
            if count>0,queue.discardIssuedPrefix(prefix) {document.discardPrefix(count)}
            let offsets=document.punctuationOffsets
            firstSeen=firstSeen.filter {offsets.contains($0.key)}
            expired=expired.intersection(offsets);settled=settled.filter {offsets.contains($0.key)}
            compaction=nil
        }
    }
    public func finish() async {
        guard !closed else {return}
        finishing=true;debounce?.cancel();debounce=nil
        await queue.drain()
        await request?.value
        guard !closed,allows(),!Task.isCancelled else {return}
        // 停止時は残った候補を最大1バッチだけ待ち、文末に新しい記号は入れない。
        startRequest();await request?.value
        guard !closed,allows(),!Task.isCancelled else {return}
        await compaction?.value
        publish(final:true);await queue.drain()
    }
    public func invalidate() {
        if !reported {
            reported=true
            diagnostics?.submit(.punctuationExpired,count:expiredCount)
            diagnostics?.submit(.punctuationApplied,count:appliedCount)
        }
        closed=true;generation+=1
        debounce?.cancel();request?.cancel();compaction?.cancel()
        document=PunctuationDocument();firstSeen=[:];settled=[:];expired=[]
    }
    public func close() async {
        invalidate()
        await debounce?.value;await request?.value;await compaction?.value
        debounce=nil;request=nil;compaction=nil
    }
}
