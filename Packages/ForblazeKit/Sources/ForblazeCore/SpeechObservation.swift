/// 本文を持たないSDK境界の観測。直近の時間範囲と終了箇所だけを扱う。
public enum SpeechObservationKind:String,Sendable {
    case accepted, duplicate, rejectedRange, resultsEnded, resultsFailed, finalizationFailed, outputOverflow, conversionFailed
}
public struct SpeechObservation:Sendable {
    public let kind:SpeechObservationKind
    public let range:AudioRange?
    public let isFinal:Bool?
    public let errorCode:Int?
    public init(_ kind:SpeechObservationKind,range:AudioRange?=nil,isFinal:Bool?=nil,errorCode:Int?=nil) {
        self.kind=kind;self.range=range;self.isFinal=isFinal;self.errorCode=errorCode
    }
}
