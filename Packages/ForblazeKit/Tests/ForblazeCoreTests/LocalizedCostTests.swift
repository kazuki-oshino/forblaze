import Testing
@testable import ForblazeCore

struct LocalizedCostTests {
    @Test func distinguishesWhyARangeCandidateCannotBeCreated() {
        #expect(InjectionPlanner.assessDifference(from:"あ",to:"あい").eligibility == .append)
        #expect(InjectionPlanner.assessDifference(from:"あいう",to:"あえう").eligibility == .belowThreshold)
        #expect(InjectionPlanner.assessDifference(from:String(repeating:"a",count:40),to:"違う文").eligibility == .insufficientSuffix)
        #expect(InjectionPlanner.assessDifference(from:"、"+String(repeating:"a",count:40),to:String(repeating:"新",count:17)+String(repeating:"a",count:40)).eligibility == .replacementTooLong)
    }
    @Test func smallerCorrectionNeedsMeasuredBenefitAndRetainsItsSuffix() throws {
        let suffix=String(repeating:"あ",count:20)
        let edit=InjectionPlanner.difference(from:"、"+suffix,to:"。"+suffix)
        let change=try #require(edit.localized)
        #expect(change.requiresCostEvidence && change.deleteCount==1)
        var costs=LocalizedEditCosts()
        #expect(!costs.shouldAttempt(change))
        costs.recordOrdinary(milliseconds:46,strokes:23)
        #expect(!costs.shouldAttempt(change))
        costs.recordLocalized(milliseconds:10)
        #expect(costs.shouldAttempt(change))
        // 入力先の範囲操作が遅ければ、同じ差分でも通常発行へ戻る。
        for _ in 0..<8 {costs.recordLocalized(milliseconds:100)}
        #expect(!costs.shouldAttempt(change))
    }
    @Test func legacyLargeEditsAndUnicodeStrokeCountsRemainCompatible() throws {
        let change=try #require(InjectionPlanner.difference(from:"、"+String(repeating:"あ",count:40),to:"。"+String(repeating:"あ",count:40)).localized)
        #expect(!change.requiresCostEvidence && LocalizedEditCosts().shouldAttempt(change))
        #expect(change.ordinaryStrokes==44)
        let emoji=LocalizedTextReplacement(expectedTail:"、"+String(repeating:"👨‍👩‍👧‍👦",count:20),replacement:"。",preservedSuffix:String(repeating:"👨‍👩‍👧‍👦",count:20))
        #expect(emoji.ordinaryStrokes==41)
    }
}
