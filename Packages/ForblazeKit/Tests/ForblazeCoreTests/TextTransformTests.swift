import Testing
@testable import ForblazeCore
struct TextTransformTests {
    @Test func personalLastWinsAndLongestSinglePass() {
        let d=DictionarySnapshot(samples:"a => 標準\nab => 長い\nx => y\ny => x",personal:"a => 個人\na => 最後\nabc => 最長")
        let transform=TextTransform(dictionary:d)
        #expect(transform.apply(to:"abc ab a xy\na") == "最長 長い 最後 yx\n最後")
        #expect(transform.apply(to:"abc ab a xy\na") == "最長 長い 最後 yx\n最後")
        #expect(d.rules.filter{$0.source=="a"}.count==1)
    }
    @Test func invalidLinesDoNotDisableValidRules() {
        let d=DictionarySnapshot(samples:"",personal:"# コメント\n不正\n => 空\na => aa\n名前 => 名前の名前\nx => z\nz => x\nabc =>\n")
        #expect(d.issues.map(\.line)==[2,3,4,5])
        #expect(TextTransform(dictionary:d).apply(to:"x z abc") == "z x ")
        #expect(TextTransform(dictionary:DictionarySnapshot(samples:"ab => z\nbc => q",personal:"")).apply(to:"abc") == "zc")
    }
}
