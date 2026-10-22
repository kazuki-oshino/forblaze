import Foundation
import Testing
import ForblazeCore

struct BlazeDynamicsTests {
    @Test func noFlamesBeforeRecordingAndTheyFinishWithoutFurtherSessionEvents() {
        var dynamics=BlazeDynamics()
        #expect(!dynamics.advance(to:0,level:1).isVisible)
        dynamics.setBurning(true,at:1)
        #expect(dynamics.advance(to:1,level:0).flame == 0)
        let lit=dynamics.advance(to:2,level:0)
        #expect(lit.flame == 1 && lit.ignition == 1 && lit.isVisible)
        dynamics.setBurning(false,at:3)
        #expect(dynamics.advance(to:3.2,level:0).flame > 0)
        let embers=dynamics.advance(to:3.5,level:0)
        #expect(embers.flame == 0 && embers.embers > 0)
        #expect(!dynamics.advance(to:3.91,level:0).isVisible)
    }
    @Test func repeatedRefreshDoesNotRestartCoolingAndReignitionIsContinuous() {
        var dynamics=BlazeDynamics()
        dynamics.setBurning(true,at:0)
        _=dynamics.advance(to:1,level:0)
        dynamics.setBurning(false,at:1)
        let cooling=dynamics.advance(to:1.15,level:0)
        dynamics.setBurning(false,at:1.15)
        #expect(dynamics.advance(to:1.15,level:0).flame == cooling.flame)
        dynamics.setBurning(true,at:1.15)
        #expect(dynamics.advance(to:1.15,level:0).flame == cooling.flame)
        #expect(dynamics.advance(to:2.2,level:0).flame == 1)
        dynamics.stopImmediately()
        #expect(!dynamics.advance(to:2.3,level:1).isVisible)
    }
    @Test func audioEnvelopeRejectsNonfiniteValuesAndSmoothsAtDifferentFrameRates() {
        func voice(rate:Int) -> Float {
            var dynamics=BlazeDynamics();dynamics.setBurning(true,at:0)
            for frame in 0...rate {_=dynamics.advance(to:Double(frame)/Double(rate),level:0.05)}
            return dynamics.advance(to:1,level:0.05).voice
        }
        #expect(abs(voice(rate:30)-voice(rate:60)) < 0.005)
        var dynamics=BlazeDynamics();dynamics.setBurning(true,at:0)
        let silent=dynamics.advance(to:0.5,level:.nan)
        #expect(silent.voice.isFinite && silent.voice == 0)
        #expect(dynamics.advance(to:0.6,level:.infinity).voice == 0)
        let rise=dynamics.advance(to:0.65,level:1).voice
        #expect(rise > 0 && rise < 1)
        let fall=dynamics.advance(to:0.70,level:0).voice
        #expect(fall > 0 && fall < rise)
    }
    @Test func policyRequiresOpenRecordingAndReducesMotionOrHidesOnFailure() {
        var state=SessionState();let id=SessionID()
        #expect(BlazePresentation.intent(enabled:true,state:state,reduceMotion:false) == .cooling)
        _=state.handle(.toggle(id))
        #expect(BlazePresentation.intent(enabled:true,state:state,reduceMotion:false) == .hidden)
        _=state.handle(.prepared(id,.init(1)))
        #expect(BlazePresentation.intent(enabled:false,state:state,reduceMotion:false) == .hidden)
        #expect(BlazePresentation.intent(enabled:true,state:state,reduceMotion:false) == .burning)
        #expect(BlazePresentation.intent(enabled:true,state:state,reduceMotion:true) == .staticGlow)
        _=state.handle(.injectionFailed(id))
        #expect(BlazePresentation.intent(enabled:true,state:state,reduceMotion:false) == .hidden)
        _=state.handle(.failed(id,.audioDevice))
        #expect(BlazePresentation.intent(enabled:true,state:state,reduceMotion:false) == .hidden)
    }
}
