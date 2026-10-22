import ForblazeCore
public struct InjectionContext:Sendable {
    public let session:SessionID
    public let epoch:TargetEpoch
    public let target:TargetID
    public init(session:SessionID,epoch:TargetEpoch,target:TargetID) {self.session=session;self.epoch=epoch;self.target=target}
}
public struct TextAcknowledgment: Sendable {
    public let deleted:Int
    public let inserted:String
    public let completed:Bool
    public let timing:TextIssueTiming?
    /// 論理的な末尾更新には含むが、実際には削除・再入力せず残した文字数。
    public let preservedSuffixCount:Int
    public let localizedDiagnostic:LocalizedEditDiagnostic?
    public init(deleted:Int,inserted:String,completed:Bool,timing:TextIssueTiming?=nil,preservedSuffixCount:Int=0,localizedDiagnostic:LocalizedEditDiagnostic?=nil) {
        self.deleted=deleted;self.inserted=inserted;self.completed=completed;self.timing=timing
        self.localizedDiagnostic=localizedDiagnostic
        self.preservedSuffixCount=max(0,min(preservedSuffixCount,deleted,inserted.count))
    }
}
public struct TextIssueTiming:Sendable {
    public var focus=Duration.zero
    public var eventPost=Duration.zero
    public var cooperativeYield=Duration.zero
    public var rangeEdit=Duration.zero
    public init() {}
}
@MainActor public protocol TextSink: AnyObject {
    /// 各小単位の発行直前にpermitを確認する。OS発行と編集成功は区別する。
    func send(_ edit:TextEdit,context:InjectionContext,permit:@escaping @MainActor ()->Bool) async -> TextAcknowledgment
}
@MainActor public final class InjectionQueue {
    private static let maximumPendingResults=32
    private enum Content {
        case segment(SegmentText),editable(EditableTextSnapshot)
        var id:SegmentID? {if case .segment(let value)=self {value.id} else {nil}}
        var isFinal:Bool {switch self {case .segment(let value):value.isFinal;case .editable(let value):value.closesEditing}}
        var flushesWaiting:Bool {switch self {case .segment(let value):value.isFinal;case .editable(let value):value.closesEditing || value.isRecognitionFinal}}
        var text:String {switch self {case .segment(let value):value.text;case .editable(let value):value.text}}
    }
    private struct Pending {
        let content:Content
        let enqueuedAt:Duration
        let receivedAt:Duration?
        let handoff:Duration?
        var firstPendingAt:Duration
        var changedAt:Duration
        var id:SegmentID? {content.id}
        var isFinal:Bool {content.isFinal}
    }
    private let sink:any TextSink
    private let clock:any SessionClock
    private let allows:()->Bool
    private let context:InjectionContext
    private let metrics:InputLatencyMetrics?
    private let policy:InputPresentationPolicy
    public var onFailure:(()->Void)?
    public var onAcknowledgment:((TextAcknowledgment)->Void)?
    public private(set) var planner=InjectionPlanner()
    public private(set) var editablePlanner=EditableTextPlanner()
    private var pending:[Pending]=[]
    public var pendingCount:Int {pending.count}
    public init(sink:any TextSink,clock:any SessionClock,context:InjectionContext,allows:@escaping ()->Bool,diagnostics:DiagnosticRecorder?=nil,policy:InputPresentationPolicy = .direct) {
        self.sink=sink;self.clock=clock;self.context=context;self.allows=allows
        self.policy=policy
        metrics=diagnostics.map {InputLatencyMetrics(diagnostics:$0,session:context.session)}
    }
    private var draining=false
    private var revision:UInt64=0
    private var worker:Task<Void,Never>?
    private var delay:Task<Void,Error>?
    private var waitingUntil:Duration?
    private var inFlight:Pending?
    private var lastIssueAt:Duration?
    public func enqueue(_ result:SegmentText,receivedAt:Duration?=nil,handoff:Duration?=nil) {
        enqueue(.segment(result),receivedAt:receivedAt,handoff:handoff)
    }
    public func enqueue(_ result:EditableTextSnapshot,receivedAt:Duration?=nil,handoff:Duration?=nil) {
        enqueue(.editable(result),receivedAt:receivedAt,handoff:handoff)
    }
    private func enqueue(_ content:Content,receivedAt:Duration?,handoff:Duration?) {
        var result=Pending(content:content,enqueuedAt:clock.elapsed,receivedAt:receivedAt,handoff:handoff,firstPendingAt:clock.elapsed,changedAt:clock.elapsed)
        guard allows() else {pending.removeAll();return}
        if let last=pending.last,last.id==result.id {
            if last.isFinal,!result.isFinal {return}
            result.firstPendingAt=last.firstPendingAt
            if last.content.text==content.text {result.changedAt=last.changedAt}
            // 同じ区間の途中更新は最新の1件へまとめる。
            pending[pending.count-1]=result
        } else {
            // 確定結果は短い別区間へ分かれて一度に届くことがある。
            // 先行区間の確定が発行中または待機中なら、その後ろへ順に残す。
            if let previous=pending.last ?? inFlight,previous.id != result.id,!previous.isFinal {fail();return}
            guard pending.count<Self.maximumPendingResults else {fail();return}
            pending.append(result)
        }
        metrics?.received(at:receivedAt)
        if result.content.flushesWaiting {delay?.cancel()}
        else if policy == .balanced,let waitingUntil,let first=pending.first,clock.elapsed+waitDuration(for:first)<waitingUntil {delay?.cancel()}
        guard worker==nil else {return}
        let generation=revision
        worker=Task { [self] in
            while !Task.isCancelled,revision==generation,!pending.isEmpty {
                var waitStart:Duration?,deadline:Duration?,waitEnd:Duration?
                while !Task.isCancelled,revision==generation,allows(),let queued=pending.first {
                    let duration=waitDuration(for:queued)
                    guard duration > .zero else {break}
                    if waitStart==nil {waitStart=clock.elapsed}
                    deadline=clock.elapsed+duration;waitingUntil=deadline
                    let wait=Task {try await clock.sleep(for:duration)};delay=wait
                    do {try await wait.value} catch {}
                    waitEnd=clock.elapsed
                    delay=nil;waitingUntil=nil
                    if policy == .direct {break}
                }
                guard !Task.isCancelled,revision==generation,allows(),let value=pending.first else {break}
                pending.removeFirst();inFlight=value
                if let assessment=plan(value) {
                    let edit=assessment.edit
                    let acknowledgment:TextAcknowledgment
                    if edit.deleteCount==0,edit.insertion.isEmpty {
                        // 文字が変わらない確定通知もplannerへ渡し、区間だけを閉じる。
                        acknowledgment = .init(deleted:0,inserted:"",completed:true)
                    } else {
                        let startedAt=clock.elapsed
                        let previousIssueEnd=lastIssueAt
                        acknowledgment=await sink.send(edit,context:context,permit:{ [weak self] in
                            guard let self else {return false}
                            return !Task.isCancelled && self.revision==generation && self.allows()
                        })
                        lastIssueAt=clock.elapsed
                        metrics?.record(enqueuedAt:value.enqueuedAt,receivedAt:value.receivedAt,handoff:value.handoff,startedAt:startedAt,finishedAt:clock.elapsed,
                                        previousIssueEnd:previousIssueEnd,waitStart:waitStart,deadline:deadline,waitEnd:waitEnd,
                                        deleted:acknowledgment.deleted-acknowledgment.preservedSuffixCount,inserted:acknowledgment.inserted.count-acknowledgment.preservedSuffixCount,completed:acknowledgment.completed,timing:acknowledgment.timing,isFinal:value.isFinal,preserved:acknowledgment.preservedSuffixCount,localized:acknowledgment.localizedDiagnostic,eligibility:assessment.eligibility)
                    }
                    // 取消直前までに発行済みの文字も、コピー用の記録へ反映する。
                    onAcknowledgment?(acknowledgment)
                    guard !Task.isCancelled,revision==generation,allows() else {break}
                    switch value.content {
                    case .segment(let value):planner.acknowledge(value,deleted:acknowledgment.deleted,inserted:acknowledgment.inserted,completed:acknowledgment.completed)
                    case .editable(let value):editablePlanner.acknowledge(value,deleted:acknowledgment.deleted,inserted:acknowledgment.inserted,completed:acknowledgment.completed)
                    }
                    if !acknowledgment.completed {fail();break}
                } else if case .segment(let segment)=value.content,segment.range.end>planner.finalizedEnd {fail();break}
                inFlight=nil
            }
            if revision==generation {pending.removeAll();inFlight=nil}
            worker=nil
        }
    }
    private func waitDuration(for value:Pending)->Duration {
        guard !value.content.flushesWaiting,!draining,let lastIssueAt,let edit=plan(value)?.edit,
              edit.deleteCount>0 || !edit.insertion.isEmpty else {return .zero}
        // 初回と確定は即時。訂正の安定待ちは最初の保留からの上限を共有する。
        let deadline=policy.deadline(lastIssue:lastIssueAt,firstPending:value.firstPendingAt,lastChange:value.changedAt,correction:edit.deleteCount>0)
        return max(.zero,deadline-clock.elapsed)
    }
    private func plan(_ value:Pending)->TextEditAssessment? {
        switch value.content {
        case .segment(let value):planner.planWithAssessment(value)
        case .editable(let value):editablePlanner.planWithAssessment(value)
        }
    }
    private func fail() {invalidate();onFailure?()}
    public func invalidate() {
        revision += 1;pending.removeAll();planner=InjectionPlanner();editablePlanner=EditableTextPlanner()
        delay?.cancel();worker?.cancel()
    }
    public func drain() async {
        draining=true;delay?.cancel()
        await worker?.value
        draining=false
    }
    public func discardIssuedPrefix(_ prefix:String)->Bool {
        guard worker==nil,pending.isEmpty,inFlight==nil,allows() else {return false}
        return editablePlanner.discardIssuedPrefix(prefix)
    }
    public func close() async {
        let task=worker;invalidate();await task?.value;worker=nil;delay=nil;inFlight=nil
        metrics?.flush()
    }
}
