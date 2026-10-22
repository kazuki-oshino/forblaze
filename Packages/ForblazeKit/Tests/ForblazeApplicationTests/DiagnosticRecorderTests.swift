import Testing
import Foundation
import ForblazeApplication
actor DiagnosticMemoryLog:DiagnosticLog {
    struct Entry:Sendable {let kind:DiagnosticKind;let count:Int;let milliseconds:Double}
    private var entries:[Entry]=[]
    private var details:[LatencyDiagnostic]=[]
    private var recoveries:[FocusRecoveryDiagnostic]=[]
    func record(_ recovery:FocusRecoveryDiagnostic) {recoveries.append(recovery)}
    func recoveryValues()->[FocusRecoveryDiagnostic] {recoveries}
    func record(_ details:LatencyDiagnostic) {self.details.append(details)}
    func detailValues()->[LatencyDiagnostic] {details}
    func record(_ kind:DiagnosticKind,count:Int,milliseconds:Double) {entries.append(.init(kind:kind,count:count,milliseconds:milliseconds))}
    func values()->[Entry] {entries}
}
@MainActor struct DiagnosticRecorderTests {
    @Test func recoveryRecordsAreFlushedInOrderWithTheirAttemptID() async {
        let log=DiagnosticMemoryLog(),recorder=DiagnosticRecorder(log:log),attempt=UUID()
        recorder.submit(.init(attempt:attempt,phase:.before,capability:.unavailable,outcome:.started))
        recorder.submit(.init(attempt:attempt,phase:.after,capability:.editable,outcome:.recovered,roleQueryStatus:0,retries:2,milliseconds:201))
        await recorder.close()
        let values=await log.recoveryValues()
        #expect(values.count==2 && values.allSatisfy {$0.attempt==attempt})
        #expect(values.first?.phase == .before && values.last?.phase == .after)
        #expect(values.last?.milliseconds==201 && recorder.failedWrites==0)
    }
    @Test func burstIsBoundedAndLastRecordSurvives() async {
        let log=DiagnosticMemoryLog(),recorder=DiagnosticRecorder(log:log)
        for count in 0..<1000 {recorder.submit(.listening,count:count);#expect(recorder.pendingCount<=64)}
        await recorder.flush();let entries=await log.values()
        #expect(!entries.isEmpty && entries.count<=64 && entries.last?.count==999)
        #expect(recorder.pendingCount==0)
    }
    @Test func closeFlushesAndRejectsFurtherRecords() async {
        let log=DiagnosticMemoryLog(),recorder=DiagnosticRecorder(log:log)
        recorder.submit(.stopping,count:2,milliseconds:20)
        await recorder.close();recorder.submit(.idle)
        await recorder.flush();let entries=await log.values()
        #expect(entries.count==1 && entries.first?.kind == .stopping)
        #expect(entries.first?.milliseconds==20)
    }
}
