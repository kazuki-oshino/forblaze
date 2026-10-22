import Foundation

public enum PunctuationChoice:String,CaseIterable,Codable,Sendable {
    case comma,period,none
    public var text:String {switch self {case .comma:"、";case .period:"。";case .none:""}}
}

public struct PunctuationCandidate:Hashable,Sendable {
    public let offset:Int
    public let original:PunctuationChoice
    public let left:String
    public let right:String
    public init(offset:Int,original:PunctuationChoice,left:String,right:String) {
        self.offset=offset;self.original=original;self.left=left;self.right=right
    }
    public func text(for choice:PunctuationChoice)->String {left+choice.text+right}
    fileprivate func sameContext(as other:Self)->Bool {offset==other.offset && left==other.left && right==other.right}
    fileprivate func extends(_ other:Self)->Bool {
        offset==other.offset && other.left.hasSuffix(left) && right.hasPrefix(other.right)
    }
}

/// 認識原文を保持し、既存の「、。｣の置換だけを許す。座標は原文のCharacter単位。
public struct PunctuationDocument:Sendable {
    private var committed=""
    private var current:SegmentText?
    private var origin=0
    private var committedProtected=Set<Int>()
    private var decisions:[Int:(PunctuationCandidate,PunctuationChoice)]=[:]
    private var attempts:[Int:[PunctuationCandidate]]=[:]
    public init() {}
    public var raw:String {committed+(current?.text ?? "")}
    public var punctuationOffsets:Set<Int> {Set(raw.enumerated().compactMap {$0.element=="、" || $0.element=="。" ? origin+$0.offset:nil})}
    private var protectedOffsets:Set<Int> {committedProtected.union((current?.protectedPunctuation ?? []).map {origin+committed.count+$0})}
    public var compactableCount:Int {committed.count>512 ? committed.count-256 : 0}
    public mutating func receive(_ value:SegmentText)->Bool {
        guard value.text.count<=RetentionLimits.segmentCharacters else {return false}
        var prefix=committed
        if let previous=current,previous.id != value.id {
            guard previous.isFinal,value.range.start>=previous.range.end else {return false}
            committedProtected.formUnion(previous.protectedPunctuation.map {origin+committed.count+$0})
            prefix+=previous.text
        } else if let previous=current,previous.isFinal {return false}
        guard prefix.count+value.text.count<=RetentionLimits.segmentCharacters*2 else {return false}
        committed=prefix;current=value
        return true
    }
    public func candidates(finalizing:Bool=false)->[PunctuationCandidate] {
        let chars=Array(raw)
        guard chars.count>2 else {return []}
        let protected=protectedOffsets
        return (1..<(chars.count-1)).compactMap {index in
            let character=chars[index]
            guard character=="、" || character=="。",!protected.contains(origin+index) else {return nil}
            // 引用・括弧と隣接する記号は、その表記規則を保つ。
            guard !"「『（【\"」』）】".contains(chars[index-1]),
                  !"「『（【\"」』）】".contains(chars[index+1]) else {return nil}
            let candidate=context(at:index,in:chars)
            let meaningful=candidate.right.filter {!$0.isWhitespace && $0 != "、" && $0 != "。"}.count
            guard !candidate.left.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
                  meaningful>0,(meaningful>=6 || candidate.right.hasSuffix("。") || finalizing) else {return nil}
            return candidate
        }
    }
    public func pendingCandidates(finalizing:Bool=false)->[PunctuationCandidate] {
        let minimumOffset=origin+raw.count-256
        return candidates(finalizing:finalizing).filter { candidate in
            let previous=attempts[candidate.offset] ?? []
            guard candidate.offset>=minimumOffset,previous.count<2,!previous.contains(where:{$0.sameContext(as:candidate)}) else {return false}
            guard let last=previous.last else {return true}
            return finalizing || !candidate.extends(last) || candidate.right.hasSuffix("。") || candidate.right.count>=last.right.count+12
        }
    }
    public mutating func markAttempted(_ candidates:[PunctuationCandidate]) {
        for candidate in candidates {attempts[candidate.offset,default:[]].append(candidate)}
    }
    public mutating func accept(_ choice:PunctuationChoice,for candidate:PunctuationCandidate) {
        guard candidate.offset>=origin+raw.count-256 else {return}
        guard candidates(finalizing:true).contains(where:{$0.extends(candidate)}) else {return}
        decisions[candidate.offset]=(candidate,choice)
    }
    public func stillContains(_ candidate:PunctuationCandidate)->Bool {
        candidates(finalizing:true).contains {$0.extends(candidate)}
    }
    public var rendered:String {renderedPrefix(rawCount:raw.count)}
    public func renderedPrefix(rawCount:Int)->String {
        let chars=Array(raw)
        let protected=protectedOffsets
        return chars.prefix(rawCount).enumerated().map {index,character in
            let offset=origin+index
            if !protected.contains(offset),let (old,choice)=decisions[offset],character=="、" || character=="。",
               context(at:index,in:chars).extends(old) {return choice.text}
            return String(character)
        }.joined()
    }
    private func context(at index:Int,in chars:[Character])->PunctuationCandidate {
        let left=String(chars[max(0,index-64)..<index])
        let following=chars.dropFirst(index+1).prefix(48)
        let end=following.firstIndex(of:"。")
        let right=end.map {String(following[...$0])} ?? String(following)
        return .init(offset:origin+index,original:chars[index]=="、" ? .comma:.period,left:left,right:right)
    }
    public mutating func discardPrefix(_ count:Int) {
        guard count>0,count<=committed.count else {return}
        committed=String(committed.dropFirst(count));origin+=count
        decisions=decisions.filter {$0.key>=origin};attempts=attempts.filter {$0.key>=origin}
        committedProtected=committedProtected.filter {$0>=origin}
    }
}
