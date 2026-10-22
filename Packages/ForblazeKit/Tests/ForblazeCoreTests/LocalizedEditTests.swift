import Testing
@testable import ForblazeCore

struct LocalizedEditTests {
    @Test func longUnchangedSuffixBecomesAOneCharacterReplacement() throws {
        let suffix=String(repeating:"変わらない文章",count:12)
        let edit=InjectionPlanner.difference(from:"前半、"+suffix,to:"前半。"+suffix)
        let localized=try #require(edit.localized)
        #expect(localized.expectedTail=="、"+suffix)
        #expect(localized.replacement=="。" && localized.preservedSuffix==suffix)
        #expect(localized.deleteCount==1)
        // 従来経路の計画は保持し、未対応の入力欄でも同じ結果へ到達する。
        #expect(edit.deleteCount==1+suffix.count && edit.insertion=="。"+suffix)
    }
    @Test func smallEditsAndAppendsDoNotPayForRangeEditing() {
        #expect(InjectionPlanner.difference(from:"今日は",to:"今日です").localized==nil)
        #expect(InjectionPlanner.difference(from:"先頭",to:"先頭に追加").localized==nil)
        #expect(InjectionPlanner.difference(from:String(repeating:"a",count:80),to:"全く別の文").localized==nil)
    }
    @Test func localizedDifferenceKeepsGraphemeClustersAndHandlesInsertionAndDeletion() throws {
        let suffix=String(repeating:"👨‍👩‍👧‍👦が🇯🇵",count:15)
        for (old,new) in [("か\u{3099}","🙂"),("", "、"),("、", "")] {
            let edit=InjectionPlanner.difference(from:"前"+old+suffix,to:"前"+new+suffix)
            let localized=try #require(edit.localized)
            #expect(localized.replacement==new && localized.preservedSuffix==suffix && localized.deleteCount==old.count)
        }
    }
}
