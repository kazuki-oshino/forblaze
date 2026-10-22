import Foundation
public struct DictionaryRule: Equatable, Sendable {
    public let source:String
    public let replacement:String
    public init(source:String,replacement:String) {self.source=source;self.replacement=replacement}
}
public enum DictionaryIssueKind: String, Sendable {case syntax, emptySource, selfExpansion, tooLarge,invalidRecognitionHint}
public struct DictionaryIssue: Equatable, Sendable {
    public let line:Int
    public let kind:DictionaryIssueKind
    public init(line:Int,kind:DictionaryIssueKind) {self.line=line;self.kind=kind}
}
public struct DictionarySnapshot: Sendable {
    public let rules:[DictionaryRule]
    public let issues:[DictionaryIssue]
    public let issueCount:Int
    public let recognitionVocabulary:RecognitionVocabulary
    public init(samples:String,personal:String) {
        var values:[String:String]=[:],invalid:[DictionaryIssue]=[],invalidCount=0
        var hints:[String]=[],seenHints=Set<String>()
        for (isPersonal,input) in [(false,samples),(true,personal)] {
            for (index,line) in input.components(separatedBy:"\n").enumerated() {
                let trimmed=line.trimmingCharacters(in:.whitespacesAndNewlines)
                if isPersonal,trimmed.hasPrefix(RecognitionVocabulary.directive) {
                    let term=RecognitionVocabulary.normalized(String(trimmed.dropFirst(RecognitionVocabulary.directive.count)))
                    let issue:DictionaryIssueKind?
                    if term==nil {issue = .invalidRecognitionHint}
                    else if !seenHints.contains(term!),hints.count>=RecognitionVocabulary.maximumTerms {issue = .tooLarge}
                    else {issue=nil;if seenHints.insert(term!).inserted {hints.append(term!)}}
                    if let issue {invalidCount += 1;if invalid.count<RetentionLimits.dictionaryIssues {invalid.append(.init(line:index+1,kind:issue))}}
                    continue
                }
                if trimmed.isEmpty || trimmed.hasPrefix("#") {continue}
                let parts=trimmed.components(separatedBy:"=>")
                let issue:DictionaryIssueKind?
                let left=parts.first?.trimmingCharacters(in:.whitespaces) ?? ""
                let right=parts.count==2 ? parts[1].trimmingCharacters(in:.whitespaces) : ""
                if parts.count != 2 {issue = .syntax}
                else if left.isEmpty {issue = .emptySource}
                else if left.count>256 || right.count>RetentionLimits.segmentCharacters || (values.count>=RetentionLimits.dictionaryRules && values[left]==nil) {issue = .tooLarge}
                else if right.contains(left) {issue = .selfExpansion}
                else {issue=nil;values[left]=right}
                // 設定画面の行番号は個人ファイルに対応する。
                if isPersonal,let issue {invalidCount += 1;if invalid.count<RetentionLimits.dictionaryIssues {invalid.append(.init(line:index+1,kind:issue))}}
            }
        }
        rules=values.map {DictionaryRule(source:$0.key,replacement:$0.value)}.sorted {
            if $0.source.count != $1.source.count {return $0.source.count>$1.source.count}
            return $0.source<$1.source
        }
        issues=invalid;issueCount=invalidCount
        recognitionVocabulary=RecognitionVocabulary(terms:hints)
    }
}
/// 原文だけに一度適用する。別の補正器も同じ値の受け渡しで接続できる。
public struct TransformedText:Sendable {
    public let text:String
    public let protectedPunctuation:Set<Int>
    public init(text:String,protectedPunctuation:Set<Int>=[]) {self.text=text;self.protectedPunctuation=protectedPunctuation}
}
public struct TextTransform: Sendable {
    private let operation:@Sendable (String,Int,Bool)->TransformedText?
    public init(_ operation:@escaping @Sendable (String)->String) {
        self.operation={original,limit,protect in
            let result=operation(original)
            guard result.count<=limit else {return nil}
            let offsets=protect && result != original ? Set(result.enumerated().compactMap {$0.element=="、" || $0.element=="。" ? $0.offset:nil}):[]
            return .init(text:result,protectedPunctuation:offsets)
        }
    }
    public init(dictionary:DictionarySnapshot) {
        let rules=dictionary.rules.map {(Array($0.source),$0.replacement,$0.replacement.enumerated().compactMap {$0.element=="、" || $0.element=="。" ? $0.offset:nil})}
        operation={ original,limit,protect in
            let input=Array(original);var index=0,output="",count=0,protected=Set<Int>()
            while index<input.count {
                if let matched=rules.first(where: {rule in
                    index+rule.0.count<=input.count && Array(input[index..<(index+rule.0.count)])==rule.0
                }) {
                    if protect {for offset in matched.2 {protected.insert(count+offset)}}
                    count += matched.1.count;guard count<=limit else {return nil}
                    output += matched.1;index += matched.0.count
                }
                else {count += 1;guard count<=limit else {return nil};output.append(input[index]);index += 1}
            }
            // 結合文字が置換境界をまたいで座標が曖昧になった場合は、全句読点を保護する。
            if protect,output.count != count {protected=Set(output.enumerated().compactMap {$0.element=="、" || $0.element=="。" ? $0.offset:nil})}
            return .init(text:output,protectedPunctuation:protected)
        }
    }
    public func apply(to original:String) -> String {operation(original,Int.max,false)?.text ?? ""}
    public func apply(to original:String,maximumCharacters:Int) -> String? {
        guard maximumCharacters>=0,original.count<=RetentionLimits.segmentCharacters else {return nil}
        return operation(original,maximumCharacters,false)?.text
    }
    public func applyWithProtection(to original:String,maximumCharacters:Int)->TransformedText? {
        guard maximumCharacters>=0,original.count<=RetentionLimits.segmentCharacters else {return nil}
        return operation(original,maximumCharacters,true)
    }
}
