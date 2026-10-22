import Foundation
public struct SegmentID: Hashable, Sendable {
    public let value: UUID
    public init(_ value: UUID = UUID()) { self.value = value }
}
public struct AudioRange: Equatable, Sendable {
    public let start: Double
    public let end: Double
    public init(_ start: Double, _ end: Double) { self.start = start; self.end = end }
}
public enum SegmentResolution: Equatable, Sendable {case update(SegmentID), duplicate, invalid}
public struct RecognitionSegments: Sendable {
    private let session: SessionID
    private var current: (id:SegmentID,range:AudioRange)?
    public private(set) var finalizedEnd: Double=0
    public init(session:SessionID) {self.session=session}
    public mutating func resolve(session:SessionID,range:AudioRange,isFinal:Bool) -> SegmentResolution {
        guard session==self.session,range.start.isFinite,range.end.isFinite,range.start>=0,range.end>=range.start else {return .invalid}
        // 実APIが確定済みの境界だけを再通知することがある。区間の状態は変更しない。
        if isFinal,range.start==range.end,range.end==finalizedEnd {return .duplicate}
        guard range.end>range.start else {return .invalid}
        if range.end <= finalizedEnd {return .duplicate}
        guard range.start >= finalizedEnd else {return .invalid}
        let id:SegmentID
        if let current {
            let sameStart=abs(current.range.start-range.start)<0.000001
            // 実APIでは確定時に同じ発話の開始時刻が移動することがある。
            // 未確定区間と重なる確定結果だけを同じ区間として更新する。
            let overlaps=range.start<current.range.end && range.end>current.range.start
            guard sameStart || (isFinal && overlaps) else {return .invalid}
            id=current.id
        } else {id=SegmentID()}
        if isFinal {finalizedEnd=range.end;current=nil}
        else {current=(id,range)}
        return .update(id)
    }
}

/// 本文を含まない、上限を設けた実API観測用の値。
public struct RecognitionMetadata: Sendable {
    public let range:AudioRange
    public let isFinal:Bool
    public init(range:AudioRange,isFinal:Bool) {self.range=range;self.isFinal=isFinal}
}
