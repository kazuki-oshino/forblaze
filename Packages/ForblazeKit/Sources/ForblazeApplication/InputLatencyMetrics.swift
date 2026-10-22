import ForblazeCore
/// 本文を保持せず、直近512回の完了した発行と遅い8件の内訳を集計する。
/// 診断ファイルへの書き込みは収録終了時にまとめ、入力経路のI/Oを増やさない。
@MainActor final class InputLatencyMetrics {
    private struct Sample {
        let queue:Double
        let issue:Double
        let recognition:Double?
    }
    private let diagnostics:DiagnosticRecorder
    private let session:SessionID
    private var slow:[LatencyDiagnostic.Sample]=[]
    private var failures:[LatencyDiagnostic.Sample]=[]
    private var operations:[LatencyField:Double]=[.localizedEligible:0,.localizedCostSkipped:0,.localizedAttempts:0,.localizedCompletions:0,.localizedUnavailable:0,.localizedStops:0,.localizedWaits:0,.correctionEvents:0,.maximumRewrite:0,.localizedBelowThreshold:0,.localizedInsufficientSuffix:0,.localizedReplacementTooLong:0]
    private var sequence=0
    private var samples:[Sample]=[]
    private var cursor=0
    private var firstRecognitionAt:Duration?
    private var firstIssue:Double?
    private var publications=0
    private var partialPublications=0
    private var rewrittenCharacters=0
    private var localizedPublications=0
    private var preservedCharacters=0
    private var flushed=false
    init(diagnostics:DiagnosticRecorder,session:SessionID) {self.diagnostics=diagnostics;self.session=session}
    func received(at time:Duration?) {
        if firstRecognitionAt==nil {firstRecognitionAt=time}
    }
    func record(enqueuedAt:Duration,receivedAt:Duration?,handoff:Duration?,startedAt:Duration,finishedAt:Duration,
                previousIssueEnd:Duration?,waitStart:Duration?,deadline:Duration?,waitEnd:Duration?,
                deleted:Int,inserted:Int,completed:Bool,timing:TextIssueTiming?,isFinal:Bool,preserved:Int=0,localized:LocalizedEditDiagnostic?=nil,eligibility:LocalizedEligibility?=nil) {
        sequence=min(1_000_000,sequence+1)
        var fields:[LatencyField:Double]=[
            .total:milliseconds(finishedAt-(receivedAt ?? enqueuedAt))+milliseconds(handoff ?? .zero),
            .queue:milliseconds(startedAt-enqueuedAt),.issue:milliseconds(finishedAt-startedAt),
            .deleted:Double(deleted),.inserted:Double(inserted),.preserved:Double(preserved),.completed:completed ? 1:0,.isFinal:isFinal ? 1:0,
            .recognitionSource:receivedAt == nil ? 0:1]
        if let receivedAt {fields[.transform]=milliseconds(enqueuedAt-receivedAt)}
        if let handoff {fields[.handoff]=milliseconds(handoff)}
        func add(_ key:LatencyField,_ amount:Double=1) {operations[key]=min(1_000_000,(operations[key] ?? 0)+amount)}
        if deleted>0 || preserved>0 {add(.correctionEvents)}
        switch eligibility {
        case .eligible:add(.localizedEligible)
        case .belowThreshold:add(.localizedBelowThreshold)
        case .insufficientSuffix:add(.localizedInsufficientSuffix)
        case .replacementTooLong:add(.localizedReplacementTooLong)
        case .append,.none:break
        }
        operations[.maximumRewrite]=max(operations[.maximumRewrite] ?? 0,Double(deleted))
        if let localized {
            fields[.localizedStage]=Double(localized.stage.rawValue)
            fields[.localizedReason]=Double(localized.reason.rawValue)
            fields[.localizedWaits]=Double(localized.waits)
            fields[.localizedIssued]=localized.issued ? 1:0
            fields[.localizedFallback]=localized.fallbackAllowed ? 1:0
            if eligibility==nil {add(.localizedEligible)}
            add(.localizedWaits,Double(localized.waits))
            if localized.attempted {add(.localizedAttempts)}
            if !localized.attempted {add(.localizedCostSkipped)}
            else if localized.stage == .finished {add(.localizedCompletions)}
            else if localized.fallbackAllowed {add(.localizedUnavailable)}
            else {add(.localizedStops)}
        }
        func overlap(_ start:Duration?,_ end:Duration?)->Double {
            guard let start,let end else {return 0}
            return milliseconds(min(end,startedAt)-max(start,enqueuedAt))
        }
        let previous=overlap(enqueuedAt,previousIssueEnd)
        let scheduled=overlap(waitStart,deadline.flatMap {limit in waitEnd.map {min(limit,$0)}})
        let overrun=overlap(deadline,waitEnd)
        fields[.previousIssue]=previous;fields[.scheduledWait]=scheduled;fields[.timerOverrun]=overrun
        fields[.worker]=max(0,(fields[.queue] ?? 0)-previous-scheduled-overrun)
        if let timing {
            fields[.focus]=milliseconds(timing.focus);fields[.eventPost]=milliseconds(timing.eventPost)
            fields[.cooperativeYield]=milliseconds(timing.cooperativeYield)
            fields[.rangeEdit]=milliseconds(timing.rangeEdit)
            fields[.sinkOther]=max(0,(fields[.issue] ?? 0)-milliseconds(timing.focus+timing.eventPost+timing.cooperativeYield+timing.rangeEdit))
        }
        if !completed {
            failures.append(.init(sequence:sequence,values:fields))
            if failures.count>8 {failures.removeFirst()}
        }
        if (fields[.total] ?? 0)>=100 || (fields[.worker] ?? 0)>=20 || (fields[.timerOverrun] ?? 0)>=20 || (fields[.issue] ?? 0)>=20 {
            slow.append(.init(sequence:sequence,values:fields))
            slow.sort {($0.values[.total] ?? 0)>($1.values[.total] ?? 0)}
            if slow.count>8 {slow.removeLast()}
        }
        rewrittenCharacters=min(1_000_000,rewrittenCharacters+deleted)
        if preserved>0 {
            localizedPublications=min(1_000_000,localizedPublications+1)
            preservedCharacters=min(1_000_000,preservedCharacters+preserved)
        }
        guard completed else {partialPublications=min(1_000_000,partialPublications+1);return}
        publications=min(1_000_000,publications+1)
        if firstIssue==nil,let firstRecognitionAt {firstIssue=milliseconds(finishedAt-firstRecognitionAt)}
        let sample=Sample(queue:milliseconds(startedAt-enqueuedAt),issue:milliseconds(finishedAt-startedAt),recognition:receivedAt.map {milliseconds(finishedAt-$0)})
        if samples.count<512 {samples.append(sample)}
        else {samples[cursor]=sample;cursor=(cursor+1)%512}
    }
    func flush() {
        guard !flushed else {return};flushed=true
        if let firstIssue {diagnostics.submit(.firstInputIssued,count:1,milliseconds:firstIssue)}
        summarize(samples.map(\.queue),kinds:(.inputQueueWaitP50,.inputQueueWaitP95,.inputQueueWaitMax))
        summarize(samples.map(\.issue),kinds:(.inputIssueDurationP50,.inputIssueDurationP95,.inputIssueDurationMax))
        summarize(samples.compactMap(\.recognition),kinds:(.recognitionToIssueP50,.recognitionToIssueP95,.recognitionToIssueMax))
        diagnostics.submit(LatencyDiagnostic(session:session.value,stage:.input,samples:slow))
        diagnostics.submit(LatencyDiagnostic(session:session.value,stage:.inputFailures,samples:failures))
        diagnostics.submit(LatencyDiagnostic(session:session.value,stage:.inputSummary,samples:[.init(sequence:0,values:operations)]))
        diagnostics.submit(.inputLocalizedPublications,count:localizedPublications)
        diagnostics.submit(.inputPreservedCharacters,count:preservedCharacters)
        diagnostics.submit(.inputPublications,count:publications)
        diagnostics.submit(.inputPartialPublications,count:partialPublications)
        diagnostics.submit(.inputRewrittenCharacters,count:rewrittenCharacters)
        samples.removeAll()
        slow.removeAll()
        failures.removeAll()
    }
    private func summarize(_ values:[Double],kinds:(DiagnosticKind,DiagnosticKind,DiagnosticKind)) {
        guard !values.isEmpty else {return}
        let sorted=values.sorted(),count=sorted.count
        // nearest-rank。countにはこの分位点に使った標本数を記録する。
        diagnostics.submit(kinds.0,count:count,milliseconds:sorted[(count+1)/2-1])
        diagnostics.submit(kinds.1,count:count,milliseconds:sorted[(count*95+99)/100-1])
        diagnostics.submit(kinds.2,count:count,milliseconds:sorted[count-1])
    }
    private func milliseconds(_ duration:Duration)->Double {
        let value=duration.components
        return max(0,Double(value.seconds)*1000+Double(value.attoseconds)/1_000_000_000_000_000)
    }
}
