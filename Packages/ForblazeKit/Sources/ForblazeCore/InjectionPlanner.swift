import Foundation
public enum LocalizedEligibility:Sendable {
    case append,belowThreshold,insufficientSuffix,replacementTooLong,eligible
}
public struct TextEditAssessment:Sendable {
    public let edit:TextEdit
    public let eligibility:LocalizedEligibility
}
public struct TextEdit: Equatable, Sendable {
    public let deleteCount:Int
    public let insertion:String
    public let localized:LocalizedTextReplacement?
    public init(deleteCount:Int,insertion:String,localized:LocalizedTextReplacement?=nil) {self.deleteCount=deleteCount;self.insertion=insertion;self.localized=localized}
}
/// 入力先で発行済みの末尾を照合できるときだけ使う、共通接尾辞を残す置換。
public struct LocalizedTextReplacement:Equatable,Sendable {
    public let expectedTail:String
    public let replacement:String
    public let preservedSuffix:String
    public var deleteCount:Int {expectedTail.count-preservedSuffix.count}
    public init(expectedTail:String,replacement:String,preservedSuffix:String) {
        self.expectedTail=expectedTail;self.replacement=replacement;self.preservedSuffix=preservedSuffix
    }
}
public struct SegmentText: Sendable {
    public let id:SegmentID
    public let range:AudioRange
    public let text:String
    public let isFinal:Bool
    public let protectedPunctuation:Set<Int>
    public init(id:SegmentID,range:AudioRange,text:String,isFinal:Bool,protectedPunctuation:Set<Int>=[]) {self.id=id;self.range=range;self.text=text;self.isFinal=isFinal;self.protectedPunctuation=protectedPunctuation}
}
public struct InjectionPlanner: Sendable {
    public private(set) var current:SegmentID?
    public private(set) var issued=""
    public private(set) var finalizedEnd:Double=0
    public init() {}
    public static func difference(from:String,to:String) -> TextEdit {
        assessDifference(from:from,to:to).edit
    }
    public static func assessDifference(from:String,to:String) -> TextEditAssessment {
        let old=Array(from),new=Array(to)
        var prefix=0
        while prefix<min(old.count,new.count),old[prefix]==new[prefix] {prefix += 1}
        let removed=old.count-prefix,insertion=String(new.dropFirst(prefix))
        var suffix=0
        while suffix<min(removed,new.count-prefix),old[old.count-1-suffix]==new[new.count-1-suffix] {suffix += 1}
        let localized:LocalizedTextReplacement?
        let replacement=String(new[prefix..<new.count-suffix])
        let eligibility:LocalizedEligibility
        if removed==0 {eligibility = .append}
        else if removed<16 {eligibility = .belowThreshold}
        else if suffix<8 {eligibility = .insufficientSuffix}
        else if replacement.utf16.count>16 {eligibility = .replacementTooLong}
        else {eligibility = .eligible}
        // 従来より短い差分は候補だけ作り、発行側が同じ対象での実測費用を確認する。
        if eligibility == .eligible {
            localized = .init(expectedTail:String(old.dropFirst(prefix)),replacement:replacement,preservedSuffix:String(old.suffix(suffix)))
        } else {localized=nil}
        return .init(edit:.init(deleteCount:removed,insertion:insertion,localized:localized),eligibility:eligibility)
    }
    public func plan(_ value:SegmentText) -> TextEdit? {
        planWithAssessment(value)?.edit
    }
    public func planWithAssessment(_ value:SegmentText) -> TextEditAssessment? {
        guard value.range.start>=finalizedEnd,value.range.end>finalizedEnd else {return nil}
        if let current,current != value.id {return nil}
        return Self.assessDifference(from:issued,to:value.text)
    }
    public mutating func acknowledge(_ value:SegmentText,deleted:Int,inserted:String,completed:Bool) {
        guard let edit=plan(value),deleted>=0,deleted<=edit.deleteCount,edit.insertion.hasPrefix(inserted) else {return}
        // 挿入は計画した削除がすべて発行された後だけ許す。
        guard inserted.isEmpty || deleted==edit.deleteCount else {return}
        current=value.id
        issued=String(issued.dropLast(deleted))+inserted
        if completed,issued==value.text,value.isFinal {
            finalizedEnd=value.range.end;current=nil;issued=""
        }
    }
}
