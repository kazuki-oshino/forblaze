import Testing
@testable import ForblazeCore
struct InjectionPlannerTests {
    @Test func shiftedFinalRevisesOnlyCurrentTextAndNextPhraseAppends() throws {
        let session=SessionID();var mapper=RecognitionSegments(session:session),planner=InjectionPlanner()
        let ranges:[AudioRange]=[.init(0,1.2),.init(0.48,1.94225),.init(1.94225,2.5),.init(2.1,2.8)]
        let texts=["今日は","今日です","次","次です"]
        let expected=[TextEdit(deleteCount:0,insertion:"今日は"),.init(deleteCount:1,insertion:"です"),.init(deleteCount:0,insertion:"次"),.init(deleteCount:0,insertion:"です")]
        var actual="既存の文："
        for index in ranges.indices {
            let final=index % 2 == 1
            guard case let .update(id)=mapper.resolve(session:session,range:ranges[index],isFinal:final) else {
                Issue.record("実測範囲に対応する更新が必要");return
            }
            let value=SegmentText(id:id,range:ranges[index],text:texts[index],isFinal:final)
            let edit=try #require(planner.plan(value))
            #expect(edit==expected[index])
            actual=String(actual.dropLast(edit.deleteCount))+edit.insertion
            planner.acknowledge(value,deleted:edit.deleteCount,inserted:edit.insertion,completed:true)
            if final {#expect(planner.plan(value)==nil)}
        }
        #expect(actual=="既存の文：今日です次です" && planner.finalizedEnd==2.8)
    }
    @Test func differencesPreserveGraphemesAndPrefix() {
        let cases:[(String,String,Int,String)]=[("今","今日は",0,"日は"),("今日は","今日です",1,"です"),("abc","a",2,""),("a","",1,""),("か\u{3099}👨‍👩‍👧‍👦x","が👨‍👩‍👧‍👦\n",1,"\n"),("🇯🇵","🙂",1,"🙂")]
        for (old,new,deletes,insertion) in cases {
            #expect(InjectionPlanner.difference(from:old,to:new)==TextEdit(deleteCount:deletes,insertion:insertion))
        }
    }
    @Test func acknowledgmentCannotDeleteExistingOrFinalizedText() {
        var p=InjectionPlanner();let id=SegmentID()
        let first=SegmentText(id:id,range:.init(0,1),text:"今日は",isFinal:false)
        #expect(p.plan(first)==TextEdit(deleteCount:0,insertion:"今日は"))
        p.acknowledge(first,deleted:0,inserted:"今日は",completed:true)
        let final=SegmentText(id:id,range:.init(0,1),text:"今日です",isFinal:true)
        #expect(p.plan(final)==TextEdit(deleteCount:1,insertion:"です"))
        p.acknowledge(final,deleted:1,inserted:"で",completed:false)
        #expect(p.issued=="今日で" && p.finalizedEnd==0)
        p.acknowledge(final,deleted:0,inserted:"す",completed:true)
        #expect(p.issued.isEmpty && p.finalizedEnd==1)
        #expect(p.plan(final)==nil)
        let next=SegmentText(id:SegmentID(),range:.init(1,2),text:"今日は",isFinal:false)
        #expect(p.plan(next)==TextEdit(deleteCount:0,insertion:"今日は"))
        let wrong=SegmentText(id:SegmentID(),range:.init(0,2),text:"削除",isFinal:false)
        #expect(p.plan(wrong)==nil)
    }
}
