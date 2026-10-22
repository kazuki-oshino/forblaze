import Testing
@testable import ForblazeCore

struct RecognitionVocabularyTests {
    @Test func onlyExplicitPersonalHintsReachRecognitionAndLegacyRulesStayIdentical() {
        let dictionary=DictionarySnapshot(samples:"# forblaze-hint-v1: sample\nサンプル => sample",
            personal:"ぐらふ => GraphQL\n# 通常のコメント\n# forblaze-hint-v1: GraphQL\n# forblaze-hint-v1: nokoribi\n# forblaze-hint-v1: GraphQL")
        #expect(dictionary.recognitionVocabulary.terms==["GraphQL","nokoribi"])
        #expect(dictionary.issueCount==0)
        #expect(TextTransform(dictionary:dictionary).apply(to:"ぐらふ")==("GraphQL"))
        #expect(DictionarySnapshot(samples:"",personal:"語 => 長い定型文").recognitionVocabulary.terms.isEmpty)
    }
    @Test func invalidOrExcessiveHintsAreVisibleAndNeverReachTheRecognizer() {
        let text=["# forblaze-hint-v1: !!!","# forblaze-hint-v1: "+String(repeating:"長",count:65)]
            + (0..<101).map {"# forblaze-hint-v1: 用語\($0)"}
        let snapshot=DictionarySnapshot(samples:"",personal:text.joined(separator:"\n"))
        #expect(snapshot.recognitionVocabulary.terms.count==100)
        #expect(snapshot.issueCount==3 && snapshot.issues.first?.kind == .invalidRecognitionHint)
    }
    @Test func vocabularyNormalizesAndBoundsUntrustedInputWithoutChangingWords() {
        let vocabulary=RecognitionVocabulary(terms:["  GraphQL  ","GraphQL","か\u{3099}","が","二行\nの文","",String(repeating:"x",count:65),"。"])
        #expect(vocabulary.terms==["GraphQL","が"])
    }
}
