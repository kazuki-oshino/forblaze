import Testing
import ForblazeCore
@testable import ForblazeApplication

@MainActor struct InputFailureDiagnosticTests {
    @Test func candidateRejectionsAndInsertionOnlyRangeCorrectionsAreCountedSeparately() async throws {
        let log=DiagnosticMemoryLog(),recorder=DiagnosticRecorder(log:log)
        let metrics=InputLatencyMetrics(diagnostics:recorder,session:SessionID())
        for eligibility in [LocalizedEligibility.belowThreshold,.insufficientSuffix,.replacementTooLong,.eligible] {
            metrics.record(enqueuedAt:.zero,receivedAt:nil,handoff:nil,startedAt:.zero,finishedAt:.milliseconds(1),
                           previousIssueEnd:nil,waitStart:nil,deadline:nil,waitEnd:nil,
                           deleted:eligibility == .eligible ? 0:5,inserted:1,completed:true,timing:nil,isFinal:false,preserved:eligibility == .eligible ? 20:0,eligibility:eligibility)
        }
        metrics.flush();await recorder.flush()
        let reports=await log.detailValues()
        let fields=try #require(reports.first {$0.stage == .inputSummary}?.samples.first?.values)
        #expect(fields[.localizedEligible]==1 && fields[.localizedAttempts]==0)
        #expect(fields[.localizedBelowThreshold]==1 && fields[.localizedInsufficientSuffix]==1 && fields[.localizedReplacementTooLong]==1)
        #expect(fields[.correctionEvents]==4 && fields[.maximumRewrite]==5)
    }
    @Test func fastFailureSurvivesEightSlowerSuccessfulPublications() async throws {
        let log=DiagnosticMemoryLog(),recorder=DiagnosticRecorder(log:log)
        let metrics=InputLatencyMetrics(diagnostics:recorder,session:SessionID())
        for index in 0..<9 {
            metrics.record(enqueuedAt:.zero,receivedAt:nil,handoff:nil,startedAt:.zero,finishedAt:.milliseconds(200+index),
                           previousIssueEnd:nil,waitStart:nil,deadline:nil,waitEnd:nil,
                           deleted:0,inserted:1,completed:true,timing:nil,isFinal:false)
        }
        let failure=LocalizedEditDiagnostic(stage:.selectionReadback,reason:.timeout,waits:5,issued:false)
        metrics.record(enqueuedAt:.zero,receivedAt:nil,handoff:nil,startedAt:.zero,finishedAt:.milliseconds(50),
                       previousIssueEnd:nil,waitStart:nil,deadline:nil,waitEnd:nil,
                       deleted:0,inserted:0,completed:false,timing:nil,isFinal:true,localized:failure)
        metrics.flush();await recorder.flush()
        let reports=await log.detailValues()
        let failed=try #require(reports.first {$0.stage == .inputFailures}?.samples.first)
        #expect(failed.sequence==10 && failed.values[.completed]==0)
        #expect(failed.values[.localizedStage]==Double(LocalizedEditDiagnostic.Stage.selectionReadback.rawValue))
        #expect(failed.values[.localizedWaits]==5 && failed.values[.localizedIssued]==0)
        let summary=try #require(reports.first {$0.stage == .inputSummary}?.samples.first)
        #expect(summary.values[.localizedAttempts]==1 && summary.values[.localizedStops]==1)
        #expect(summary.values[.localizedCompletions]==0)
        #expect(reports.first {$0.stage == .input}?.samples.count==8)
    }

    @Test func diagnosticFailureRetentionIsBoundedAndFlushesOnce() async {
        let log=DiagnosticMemoryLog(),recorder=DiagnosticRecorder(log:log)
        let metrics=InputLatencyMetrics(diagnostics:recorder,session:SessionID())
        for _ in 0..<20 {
            metrics.record(enqueuedAt:.zero,receivedAt:nil,handoff:nil,startedAt:.zero,finishedAt:.milliseconds(1),
                           previousIssueEnd:nil,waitStart:nil,deadline:nil,waitEnd:nil,
                           deleted:1,inserted:0,completed:false,timing:nil,isFinal:false)
        }
        metrics.flush();metrics.flush();await recorder.flush()
        let reports=await log.detailValues().filter {$0.stage == .inputFailures}
        #expect(reports.count==1 && reports.first?.samples.count==8)
        #expect(reports.first?.samples.first?.sequence==13 && reports.first?.samples.last?.sequence==20)
    }
}
