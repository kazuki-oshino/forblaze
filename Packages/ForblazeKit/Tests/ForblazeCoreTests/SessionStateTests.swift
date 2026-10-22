import Testing
import ForblazeCore
struct SessionStateTests {
    @Test func lateFailureCannotReplaceStopReasonButCleanupFailureRemainsVisible() {
        for manual in [true,false] {
            var state=SessionState();let id=SessionID()
            _=state.handle(.toggle(id));_=state.handle(.prepared(id,.init(7)))
            if manual {_=state.handle(.manualInput)}
            else {_=state.handle(.targetChanged(.init(8),issue:.unavailable))}
            let original=state
            _=state.handle(.failed(id,.target(.changed)))
            _=state.handle(.targetChanged(.init(9)))
            #expect(state==original)
            _=state.handle(.failed(id,.cleanup))
            #expect(state.lastError == .cleanup && state.phase == .stopping)
        }
    }

    @Test func idleInterruptDoesNotInventAnErrorAndPreservesRealFailure() {
        var state=SessionState()
        _=state.handle(.interrupt(.interrupted))
        #expect(state.phase == .idle && state.lastError==nil)
        let id=SessionID();_=state.handle(.toggle(id));_=state.handle(.failed(id,.preparation));_=state.handle(.cleaned(id))
        _=state.handle(.interrupt(.interrupted))
        #expect(state.lastError == .preparation)
    }

    @Test func uncertainPublicationSuspendsAndRequiresNewSession() {
        let id=SessionID();var state=SessionState()
        _=state.handle(.toggle(id));_=state.handle(.prepared(id,.init(1)))
        _=state.handle(.injectionFailed(SessionID()));#expect(state.permission == .open)
        _=state.handle(.injectionFailed(id))
        #expect(state.phase == .listening && state.permission == .suspended && state.lastError == .injection)
        _=state.handle(.prepared(id,.init(1)));#expect(state.permission == .suspended)
        let effects=state.handle(.toggle(SessionID()));#expect(effects==[.cancel(id)])
    }
    @Test func manualEditingStopsWithoutFinalizationAndOnePressStartsANewSession() {
        let id=SessionID(),next=SessionID();var state=SessionState()
        _=state.handle(.toggle(id));_=state.handle(.prepared(id,.init(1)))
        #expect(state.handle(.manualInput)==[.cancel(id)])
        #expect(state.phase == .stopping && state.permission == .closed && state.lastError==nil)
        #expect(state.handle(.targetChanged(.init(2))).isEmpty)
        #expect(state.lastError==nil)
        #expect(state.handle(.manualInput).isEmpty)
        _=state.handle(.cleaned(id))
        #expect(state.phase == .idle && state.lastError==nil)
        #expect(state.handle(.toggle(next))==[.prepare(next)])
        _=state.handle(.prepared(next,.init(2)))
        #expect(state.allows(next,.init(2)) && !state.allows(id,.init(1)))
    }
    @Test func normalLifecycleAndDuplicateCallbacks() {
        let id=SessionID(), old=SessionID(); var s=SessionState()
        #expect(s.handle(.toggle(id)) == [.prepare(id)])
        #expect(s.phase == .preparing && s.permission == .closed)
        #expect(s.handle(.prepared(old,.init(1))).isEmpty)
        _=s.handle(.prepared(id,.init(1)))
        #expect(s.allows(id,.init(1)))
        #expect(s.handle(.toggle(old)) == [.finish(id)])
        #expect(s.phase == .finishing && s.allows(id,.init(1)))
        #expect(s.handle(.finalized(old)).isEmpty)
        #expect(s.handle(.finalized(id)) == [.cancel(id)])
        #expect(s.phase == .stopping && !s.allows(id,.init(1)))
        #expect(s.handle(.toggle(old)).isEmpty)
        _=s.handle(.cleaned(id))
        #expect(s.phase == .idle)
        #expect(s.handle(.prepared(id,.init(1))).isEmpty)
    }
    @Test func cancellationSuspensionAndFailures() {
        for event in [SessionEvent.manualInput,.targetChanged(.init(2)),.timeout(SessionID()),.interrupt(.audioDevice)] {
            let id=SessionID(); var s=SessionState(); _=s.handle(.toggle(id));_=s.handle(.prepared(id,.init(1)))
            _=s.handle(event)
            if case .timeout = event { #expect(s.phase == .listening) }
            else { #expect(!s.allows(id,.init(1))) }
        }
        let id=SessionID();var s=SessionState();_=s.handle(.toggle(id))
        #expect(s.handle(.toggle(SessionID())) == [.cancel(id)])
        _=s.handle(.prepared(id,.init(1)));#expect(s.phase == .stopping)
        _=s.handle(.failed(id,.cleanup));#expect(s.lastError == .cleanup && s.phase == .stopping)
        _=s.handle(.cleaned(id));#expect(s.lastError == .cleanup)
        _=s.handle(.toggle(SessionID()));#expect(s.lastError == nil)
    }
    @Test func finishingInterruptionsAndNoAutomaticResume() {
        for eventIndex in 0..<4 {
            let id=SessionID();var s=SessionState();_=s.handle(.toggle(id));_=s.handle(.prepared(id,.init(1)));_=s.handle(.toggle(SessionID()))
            let event:SessionEvent = [.manualInput,.targetChanged(.init(2)),.toggle(SessionID()),.timeout(id)][eventIndex]
            #expect(s.handle(event) == [.cancel(id)])
            #expect(s.phase == .stopping && s.permission == .closed)
        }
        let id=SessionID();var s=SessionState();_=s.handle(.toggle(id));_=s.handle(.prepared(id,.init(1)));_=s.handle(.manualInput)
        _=s.handle(.prepared(id,.init(1)));#expect(s.phase == .stopping && s.permission == .closed)
        #expect(s.handle(.toggle(SessionID())).isEmpty)
    }
}
