import Foundation

/// 認識用として明示された短い用語だけを持つ、収録ごとの不変値。
public struct RecognitionVocabulary:Sendable,Equatable {
    public static let directive="# forblaze-hint-v1:"
    public static let maximumTerms=100
    public let terms:[String]
    public init(terms:[String]=[]) {
        var seen=Set<String>()
        self.terms=Array(terms.compactMap {Self.normalized($0)}.filter {seen.insert($0).inserted}.prefix(Self.maximumTerms))
    }
    public static func normalized(_ value:String)->String? {
        guard value.rangeOfCharacter(from:.controlCharacters)==nil else {return nil}
        let term=value.trimmingCharacters(in:.whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard !term.isEmpty,term.count<=64,term.rangeOfCharacter(from:.letters) != nil else {return nil}
        return term
    }
}
