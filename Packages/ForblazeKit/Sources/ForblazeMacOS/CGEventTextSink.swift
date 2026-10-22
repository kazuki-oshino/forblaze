import CoreGraphics
import ForblazeCore
import ForblazeApplication
enum TextStroke:Equatable {case backspace,unicode(String)}
@MainActor protocol TextEventPoster:AnyObject {func post(_ stroke:TextStroke) -> Bool}
@MainActor private final class NativeTextEventPoster:TextEventPoster {
    func post(_ stroke:TextStroke) -> Bool {
        let code:CGKeyCode
        switch stroke {case .backspace:code=51;case .unicode:code=0}
        guard let down=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:true),
              let up=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:false) else {return false}
        for event in [down,up] {
            event.flags=[];event.setIntegerValueField(.eventSourceUserData,value:InjectionMarker.value)
            if case .unicode(let text)=stroke {
                var units=Array(text.utf16)
                event.keyboardSetUnicodeString(stringLength:units.count,unicodeString:&units)
            }
        }
        down.post(tap:.cgSessionEventTap);up.post(tap:.cgSessionEventTap)
        return true
    }
}
enum UnicodeChunks {
    static func split(_ text:String,maximumUTF16:Int=16) -> [String]? {
        guard maximumUTF16>0 else {return nil}
        var chunks:[String]=[],current="",units=0
        for character in text {
            let value=String(character),count=value.utf16.count
            guard count<=maximumUTF16 else {return nil}
            if units+count>maximumUTF16 {chunks.append(current);current="";units=0}
            current += value;units += count
        }
        if !current.isEmpty {chunks.append(current)}
        return chunks
    }
}
@MainActor public final class CGEventTextSink:TextSink {
    private let focus:any FocusService
    private let poster:any TextEventPoster
    private let clock:any SessionClock
    private var costContext:InjectionContext?
    private var costs=LocalizedEditCosts()
    public init(focus:any FocusService,clock:any SessionClock=MonotonicSessionClock()) {self.focus=focus;self.clock=clock;poster=NativeTextEventPoster()}
    init(focus:any FocusService,poster:any TextEventPoster,clock:any SessionClock=MonotonicSessionClock()) {self.focus=focus;self.poster=poster;self.clock=clock}
    public func send(_ edit:TextEdit,context:InjectionContext,permit:@escaping @MainActor ()->Bool) async -> TextAcknowledgment {
        if costContext?.session != context.session || costContext?.epoch != context.epoch || costContext?.target != context.target {
            costContext=context;costs=LocalizedEditCosts()
        }
        guard edit.deleteCount>=0,let chunks=UnicodeChunks.split(edit.insertion) else {return .init(deleted:0,inserted:"",completed:false)}
        var deleted=0,inserted=""
        var timing=TextIssueTiming()
        var localizedDiagnostic:LocalizedEditDiagnostic?
        func acknowledgment(_ completed:Bool)->TextAcknowledgment {.init(deleted:deleted,inserted:inserted,completed:completed,timing:timing,localizedDiagnostic:localizedDiagnostic)}
        func ready() async -> Bool {
            guard permit(),!Task.isCancelled else {return false}
            let start=clock.elapsed
            let target=await focus.read()
            timing.focus += clock.elapsed-start
            return permit() && !Task.isCancelled && target.epoch==context.epoch && target.target.id==context.target && target.target.permitsInput
        }
        func post(_ stroke:TextStroke)->Bool {
            let start=clock.elapsed,result=poster.post(stroke)
            timing.eventPost += clock.elapsed-start;return result
        }
        func yield() async {
            let start=clock.elapsed;await Task.yield();timing.cooperativeYield += clock.elapsed-start
        }
        if let change=edit.localized,!costs.shouldAttempt(change) {
            localizedDiagnostic = .init(stage:.validation,reason:costs.hasEvidence ? .unfavorableCost:.unmeasuredCost,fallbackAllowed:true,attempted:false)
        }
        if let change=edit.localized,costs.shouldAttempt(change),change.expectedTail.count==edit.deleteCount,change.replacement.utf16.count<=16,
           (change.replacement+change.preservedSuffix).utf16.elementsEqual(edit.insertion.utf16),
           let replacer=focus as? any LocalizedTextReplacing {
            let start=clock.elapsed
            // AXで範囲と本文を照合し、通常と同じマーカー付きキーイベントを1単位だけ発行する。
            let report=await replacer.replaceReporting(change,context:context,permit:permit,emit:{ [poster,clock] in
                guard permit(),!Task.isCancelled else {return false}
                let began=clock.elapsed
                let posted=poster.post(change.replacement.isEmpty ? .backspace:.unicode(change.replacement))
                timing.eventPost += clock.elapsed-began
                return posted
            })
            localizedDiagnostic=report.diagnostic
            if report.outcome == .applied {costs.recordLocalized(milliseconds:milliseconds(clock.elapsed-start))}
            timing.rangeEdit += max(.zero,clock.elapsed-start-timing.eventPost)
            switch report.outcome {
            case .unavailable:break
            case .applied,.stopped(issued:true):
                return .init(deleted:edit.deleteCount,inserted:edit.insertion,completed:report.outcome == .applied,timing:timing,preservedSuffixCount:change.preservedSuffix.count,localizedDiagnostic:localizedDiagnostic)
            case .stopped(issued:false):return acknowledgment(false)
            }
        }
        let ordinaryStart=clock.elapsed
        for _ in 0..<edit.deleteCount {
            guard await ready(),post(.backspace) else {return acknowledgment(false)}
            deleted += 1;await yield()
        }
        for chunk in chunks {
            guard await ready(),post(.unicode(chunk)) else {return acknowledgment(false)}
            inserted += chunk;await yield()
        }
        costs.recordOrdinary(milliseconds:milliseconds(clock.elapsed-ordinaryStart),strokes:edit.deleteCount+chunks.count)
        return acknowledgment(true)
    }
    private func milliseconds(_ duration:Duration)->Double {
        Double(duration.components.seconds)*1000+Double(duration.components.attoseconds)/1_000_000_000_000_000
    }
}
