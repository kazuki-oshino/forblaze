import Testing
@testable import ForblazeCore
struct RetentionTests {
    @Test func oversizedReplacementCannotBuildUnboundedOutput() {
        let dictionary=DictionarySnapshot(samples:"",personal:"a => "+String(repeating:"b",count:4097))
        #expect(dictionary.rules.isEmpty)
        var errors=""
        for _ in 0..<1000 {errors += "不正\n"}
        let invalid=DictionarySnapshot(samples:"",personal:errors)
        #expect(invalid.issues.count<=RetentionLimits.dictionaryIssues && invalid.issueCount==1000)
        let expanding=TextTransform(dictionary:.init(samples:"a => bbbbb",personal:""))
        #expect(expanding.apply(to:"aaa",maximumCharacters:10)==nil)
        #expect(expanding.apply(to:"a",maximumCharacters:10)=="bbbbb")
    }
    @Test func manyFinalizedSegmentsKeepNoTextHistory() {
        let session=SessionID();var segments=RecognitionSegments(session:session),planner=InjectionPlanner()
        for i in 0..<10000 {
            let range=AudioRange(Double(i),Double(i+1))
            if case .update(let id)=segments.resolve(session:session,range:range,isFinal:true) {
                let text=SegmentText(id:id,range:range,text:"同じ文",isFinal:true)
                planner.acknowledge(text,deleted:0,inserted:text.text,completed:true)
                #expect(planner.issued.isEmpty && planner.current==nil)
            } else {Issue.record("別区間を拒否した")}
        }
        #expect(segments.finalizedEnd==10000 && planner.finalizedEnd==10000)
    }
}
