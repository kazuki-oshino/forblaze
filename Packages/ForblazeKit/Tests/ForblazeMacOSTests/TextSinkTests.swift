import Testing
import ForblazeCore
import ForblazeApplication
@testable import ForblazeMacOS
@MainActor private final class SinkFocus:FocusService,LocalizedTextReplacing {
    var onChange:((FocusSnapshot)->Void)?
    var snapshot=FocusSnapshot(target:.init(id:.init(process:1,element:1),capability:.editable),epoch:.init(1))
    var onRead:(()->Void)?
    var replacementOutcome=LocalizedReplacementOutcome.unavailable
    var beforeReplacement:(()->Void)?
    func read() async -> FocusSnapshot {onRead?();return snapshot}
    func start() {}
    func stop() async {}
    func replace(_ change:LocalizedTextReplacement,context:InjectionContext,permit:@escaping @MainActor ()->Bool,
                 emit:@escaping @MainActor () -> Bool) async -> LocalizedReplacementOutcome {
        beforeReplacement?()
        if replacementOutcome == .applied || replacementOutcome == .stopped(issued:true) {
            guard permit(),emit() else {return .stopped(issued:false)}
        }
        return replacementOutcome
    }
}
@MainActor private final class PosterFake:TextEventPoster {
    var calls:[TextStroke]=[]
    var afterPost:(()->Void)?
    var failAt:Int?
    func post(_ stroke:TextStroke) -> Bool {
        if calls.count==failAt {return false}
        calls.append(stroke);afterPost?();return true
    }
}
@MainActor private final class SinkClock:SessionClock {
    var elapsed=Duration.zero
    func sleep(for duration:Duration) async throws {elapsed += duration}
}
@MainActor struct TextSinkTests {
    @Test func smallerRangeRequiresSuccessfulTimingEvidenceInTheSameSession() async throws {
        let focus=SinkFocus(),poster=PosterFake(),clock=SinkClock()
        let sink=CGEventTextSink(focus:focus,poster:poster,clock:clock)
        focus.replacementOutcome = .applied
        focus.onRead={clock.elapsed += .milliseconds(5)}
        poster.afterPost={clock.elapsed += .milliseconds(1)}
        focus.beforeReplacement={clock.elapsed += .milliseconds(10)}
        let small=InjectionPlanner.difference(from:"、"+String(repeating:"あ",count:20),to:"。"+String(repeating:"あ",count:20))
        let first=await sink.send(small,context:context,permit:{true})
        #expect(first.localizedDiagnostic?.attempted==false && first.preservedSuffixCount==0)
        let legacy=InjectionPlanner.difference(from:"、"+String(repeating:"あ",count:40),to:"。"+String(repeating:"あ",count:40))
        _=await sink.send(legacy,context:context,permit:{true})
        poster.calls=[]
        let improved=await sink.send(small,context:context,permit:{true})
        #expect(improved.localizedDiagnostic?.stage == .finished)
        #expect(improved.preservedSuffixCount==20 && poster.calls==[.unicode("。")])
        let next=InjectionContext(session:SessionID(),epoch:context.epoch,target:context.target)
        let fresh=await sink.send(small,context:next,permit:{true})
        #expect(fresh.localizedDiagnostic?.attempted==false && fresh.preservedSuffixCount==0)
    }
    let context=InjectionContext(session:SessionID(),epoch:.init(1),target:.init(process:1,element:1))
    @Test func unicodeChunksKeepGraphemesAndSurrogates() {
        let text="あいう🙂👨‍👩‍👧‍👦が\n🇯🇵";let chunks=UnicodeChunks.split(text,maximumUTF16:16)
        #expect(chunks?.joined()==text)
        #expect(chunks?.allSatisfy{$0.utf16.count<=16} == true)
        #expect(UnicodeChunks.split("👨‍👩‍👧‍👦",maximumUTF16:2)==nil)
    }
    @Test func cancellationAndFailuresReturnOnlyPostedPortion() async {
        let focus=SinkFocus(),poster=PosterFake()
        var allowed=true;let actual=CGEventTextSink(focus:focus,poster:poster)
        poster.afterPost={allowed=false}
        let stopped=await actual.send(.init(deleteCount:3,insertion:"残り"),context:context,permit:{allowed})
        #expect(stopped.deleted==1 && stopped.inserted.isEmpty && !stopped.completed)
        #expect(poster.calls==[.backspace])
        allowed=true;poster.calls=[];poster.afterPost=nil;poster.failAt=1
        let failed=await actual.send(.init(deleteCount:0,insertion:String(repeating:"あ",count:20)),context:context,permit:{allowed})
        #expect(failed.inserted==String(repeating:"あ",count:16) && !failed.completed)
        focus.snapshot = .init(target:.init(id:.init(process:2,element:1),capability:.editable),epoch:.init(2))
        poster.calls=[];let changed=await actual.send(.init(deleteCount:1,insertion:"x"),context:context,permit:{true})
        #expect(changed.deleted==0 && poster.calls.isEmpty)
    }
    @Test func separatelyTimesFocusAndPostingIncludingCancelledPublication() async throws {
        let focus=SinkFocus(),poster=PosterFake(),clock=SinkClock()
        let actual=CGEventTextSink(focus:focus,poster:poster,clock:clock)
        focus.onRead={clock.elapsed += .milliseconds(5)}
        poster.afterPost={clock.elapsed += .milliseconds(2)}
        let complete=await actual.send(.init(deleteCount:2,insertion:"文"),context:context,permit:{true})
        #expect(complete.completed && complete.timing?.focus == .milliseconds(15) && complete.timing?.eventPost == .milliseconds(6))
        #expect(complete.timing?.cooperativeYield == .zero)
        var allowed=true
        poster.afterPost={clock.elapsed += .milliseconds(2);allowed=false}
        let partial=await actual.send(.init(deleteCount:2,insertion:"文"),context:context,permit:{allowed})
        #expect(!partial.completed && partial.deleted==1 && partial.timing?.focus == .milliseconds(5) && partial.timing?.eventPost == .milliseconds(2))
    }
    @Test func localizedEditPostsOneUnitAndAcknowledgesTheLogicalTailOnlyOnce() async throws {
        let focus=SinkFocus(),poster=PosterFake(),sink=CGEventTextSink(focus:focus,poster:poster),suffix=String(repeating:"あ",count:85)
        focus.replacementOutcome = .applied
        let edit=InjectionPlanner.difference(from:"、"+suffix,to:"。"+suffix)
        let result=await sink.send(edit,context:context,permit:{true})
        #expect(poster.calls == [.unicode("。")])
        #expect(result.completed && result.deleted==86 && result.inserted=="。"+suffix && result.preservedSuffixCount==85)
        poster.calls=[]
        let deletion=await sink.send(InjectionPlanner.difference(from:"、"+suffix,to:suffix),context:context,permit:{true})
        #expect(poster.calls == [.backspace] && deletion.completed && deletion.preservedSuffixCount==85)
    }
    @Test func unsupportedRangeUsesFreshChecksForEveryUnitAndStillRejectsProtectedTargets() async {
        let focus=SinkFocus(),poster=PosterFake(),sink=CGEventTextSink(focus:focus,poster:poster),suffix=String(repeating:"あ",count:85)
        var reads=0;focus.onRead={reads += 1}
        let edit=InjectionPlanner.difference(from:"、"+suffix,to:"。"+suffix)
        let result=await sink.send(edit,context:context,permit:{true})
        #expect(result.completed && result.preservedSuffixCount==0 && reads==92 && poster.calls.count==92)
        reads=0;poster.calls=[]
        focus.onRead={
            reads += 1
            if reads==2 {focus.snapshot = .init(target:.init(id:.init(process:1,element:1),capability:.protected),epoch:.init(1))}
        }
        let stopped=await sink.send(edit,context:context,permit:{true})
        #expect(!stopped.completed && stopped.deleted==1 && poster.calls == [.backspace])
    }
    @Test func attemptedRangeEditNeverFallsBackAndCancellationRejectsItsEvent() async {
        let suffix=String(repeating:"あ",count:85),edit=InjectionPlanner.difference(from:"、"+suffix,to:"。"+suffix)
        for issued in [false,true] {
            let focus=SinkFocus(),poster=PosterFake(),sink=CGEventTextSink(focus:focus,poster:poster)
            focus.replacementOutcome = .stopped(issued:issued)
            let result=await sink.send(edit,context:context,permit:{true})
            #expect(!result.completed && poster.calls.count==(issued ? 1:0))
            #expect(result.preservedSuffixCount==(issued ? 85:0))
        }
        let focus=SinkFocus(),poster=PosterFake(),sink=CGEventTextSink(focus:focus,poster:poster)
        var allowed=true;focus.replacementOutcome = .applied;focus.beforeReplacement={allowed=false}
        let result=await sink.send(edit,context:context,permit:{allowed})
        #expect(!result.completed && poster.calls.isEmpty)
    }
}
