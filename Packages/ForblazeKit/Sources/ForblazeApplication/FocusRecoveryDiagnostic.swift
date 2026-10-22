import Foundation
import ForblazeCore

/// 入力欄の本文・タイトル・アプリ名を受け取らない、開始時の回復記録。
public struct FocusRecoveryDiagnostic:Sendable,Encodable {
    public enum Phase:String,Sendable,Encodable {case before,after}
    public enum Capability:String,Sendable,Encodable {
        case editable,noneditable,protected,unavailable
        public init(_ value:TargetCapability) {
            switch value {
            case .editable:self = .editable
            case .noneditable:self = .noneditable
            case .protected:self = .protected
            case .unavailable:self = .unavailable
            }
        }
    }
    public enum Outcome:String,Sendable,Encodable {case started,recovered,rejected,timedOut,unavailable,cancelled,invalidated}
    public enum Manual:String,Sendable,Encodable {case notAttempted,unsupported,alreadyEnabled,enabled,failed}
    public let attempt:UUID
    public let phase:Phase
    public let capability:Capability
    public let outcome:Outcome
    public let roleQueryStatus:Int32?
    public let manual:Manual
    public let retries:Int
    public let milliseconds:Double
    public init(attempt:UUID,phase:Phase,capability:TargetCapability,outcome:Outcome,
                roleQueryStatus:Int32?=nil,manual:Manual = .notAttempted,retries:Int=0,milliseconds:Double=0) {
        self.attempt=attempt;self.phase=phase;self.capability=Capability(capability);self.outcome=outcome
        self.roleQueryStatus=roleQueryStatus;self.manual=manual;self.retries=min(max(0,retries),30)
        self.milliseconds=milliseconds.isFinite ? min(max(0,milliseconds),86_400_000):0
    }
}
