import ForblazeCore
/// 本文を受け取らず、型付き状態と件数・時間だけを保存する。
@MainActor public final class DiagnosticRecorder {
    private enum Entry {
        case metric(DiagnosticKind,Int,Double)
        case details(LatencyDiagnostic)
        case recovery(FocusRecoveryDiagnostic)
    }
    private let log:any DiagnosticLog
    private var pending:[Entry]=[]
    private var worker:Task<Void,Never>?
    private var closed=false
    public var pendingCount:Int {pending.count}
    public private(set) var failedWrites=0
    public init(log:any DiagnosticLog) {self.log=log}
    public func submit(_ kind:DiagnosticKind,count:Int=0,milliseconds:Double=0) {
        enqueue(.metric(kind,count,milliseconds))
    }
    public func submit(_ details:LatencyDiagnostic) {enqueue(.details(details))}
    public func submit(_ recovery:FocusRecoveryDiagnostic) {enqueue(.recovery(recovery))}
    private func enqueue(_ entry:Entry) {
        guard !closed else {return}
        if pending.count==64 {pending.removeFirst()}
        pending.append(entry)
        guard worker==nil else {return}
        worker=Task { [self] in
            while !pending.isEmpty {
                let entry=pending.removeFirst()
                do {
                    switch entry {
                    case .metric(let kind,let count,let milliseconds):try await log.record(kind,count:count,milliseconds:milliseconds)
                    case .details(let details):try await log.record(details)
                    case .recovery(let recovery):try await log.record(recovery)
                    }
                }
                catch {failedWrites=min(failedWrites+1,1_000_000)}
            }
            worker=nil
        }
    }
    public func flush() async {await worker?.value}
    public func close() async {closed=true;await flush()}
}
