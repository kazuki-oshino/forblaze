/// 本文・入力先識別子を持たない、一回の局所置換の結果。
public struct LocalizedEditDiagnostic:Sendable,Equatable {
    public enum Stage:Int,Sendable {case validation=1,selection,selectionReadback,publication,replacementReadback,restoration,restorationReadback,finished}
    public enum Reason:Int,Sendable {case none=0,unsupported,textUnavailable,targetChanged,cancelled,textMismatch,selectionMismatch,timeout,selectionFailed,publicationFailed,busy,unmeasuredCost,unfavorableCost}
    public let stage:Stage
    public let reason:Reason
    public let waits:Int
    public let issued:Bool
    public let fallbackAllowed:Bool
    public let attempted:Bool
    public init(stage:Stage,reason:Reason,waits:Int=0,issued:Bool=false,fallbackAllowed:Bool=false,attempted:Bool=true) {
        self.stage=stage;self.reason=reason;self.waits=max(0,min(20,waits));self.issued=issued
        self.fallbackAllowed=fallbackAllowed
        self.attempted=attempted
    }
}
