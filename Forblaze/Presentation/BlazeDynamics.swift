import Foundation
import ForblazeCore

enum BlazePresentation:Equatable {
    case hidden, burning, cooling, staticGlow
    static func intent(enabled:Bool,state:SessionState,reduceMotion:Bool)->Self {
        guard enabled,state.lastError == nil else {return .hidden}
        if state.phase == .listening {
            guard state.permission == .open else {return .hidden}
            return reduceMotion ? .staticGlow:.burning
        }
        guard !reduceMotion,state.phase != .preparing else {return .hidden}
        return .cooling
    }
}

/// 描画時刻だけで遷移を進める。遅延コールバックを使わず、再点火で古い消火処理が残らない。
struct BlazeDynamics {
    struct Frame:Equatable {
        var flame:Float=0
        var embers:Float=0
        var ignition:Float=0
        var voice:Float=0
        var time:Float=0
        var isVisible:Bool {flame > 0 || embers > 0}
    }
    private(set) var burning=false
    private var transitionTime:Double=0
    private var epoch:Double?
    private var lastTime:Double?
    private var initial=Frame()
    private var frame=Frame()
    mutating func setBurning(_ value:Bool,at time:Double) {
        guard burning != value,time.isFinite else {return}
        updateTransition(at:time)
        initial=frame;transitionTime=time;burning=value
        if epoch == nil {epoch=time}
        lastTime=time
    }
    mutating func stopImmediately() {self=Self()}
    mutating func advance(to time:Double,level:Float)->Frame {
        guard time.isFinite else {return frame}
        updateTransition(at:time)
        let dt=max(0,min(time-(lastTime ?? time),1))
        let target=burning && level.isFinite ? min(max(level*20,0),1):0
        let tau=target>frame.voice ? 0.08:0.42
        frame.voice+=(target-frame.voice)*Float(1-exp(-dt/tau))
        frame.time=Float(max(0,time-(epoch ?? time)))
        lastTime=time
        return frame
    }
    private mutating func updateTransition(at time:Double) {
        let elapsed=max(0,time-transitionTime)
        func ease(_ duration:Double)->Float {
            let x=Float(min(elapsed/duration,1))
            return x*x*(3-2*x)
        }
        if burning {
            frame.flame=initial.flame+(1-initial.flame)*ease(0.35)
            frame.embers=initial.embers+(1-initial.embers)*ease(0.65)
            frame.ignition=initial.ignition+(1-initial.ignition)*ease(0.9)
        } else {
            frame.flame=initial.flame*(1-ease(0.4))
            frame.embers=initial.embers*(1-ease(0.9))
            if !frame.isVisible {frame.ignition=0}
        }
    }
}
