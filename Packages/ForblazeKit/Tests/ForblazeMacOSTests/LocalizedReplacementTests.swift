import Foundation
import Testing
import Synchronization
import ForblazeCore
import ForblazeApplication
@testable import ForblazeMacOS

private final class RangeAccess:FocusAccessibilityAccess {
    enum ReadbackLag:CaseIterable {case snapshot,range,selectedText}
    struct State {
        var text:AccessibleTextState
        var focused=1
        var capability=TargetCapability.editable
        var settable=true
        var readable=true
        var selectionWorks=true
        var wrongSelection=false
        var capabilityReads=0
        var selections:[NSRange]=[]
        var posts=0
        var authorized=true
        var revokeAfterSelection=false
        var changeFocusAfterSelection=false
        var revokeAfterPost=false
        var mutateAfterPost=false
        var selectionReadbackDelay=0
        var restorationReadbackDelay=0
        var readbackLag=ReadbackLag.snapshot
        var pendingReadback:AccessibleTextState?
        var pendingReadbackCount=0
    }
    let state:Mutex<State>
    init(text:String,caret:Int) {state=Mutex(.init(text:.init(value:text,selection:NSRange(location:caret,length:0),selectedText:"")))}
    func application(process:Int32)->Int {0}
    func focusedElement(in app:Int)->Int? {state.withLock {$0.focused}}
    func capability(of element:Int)->TargetCapability {state.withLock {$0.capabilityReads += 1;return $0.capability}}
    func elementsEqual(_ lhs:Int,_ rhs:Int)->Bool {lhs==rhs}
    func manualAccessibility(in app:Int)->ManualAccessibilityState {.unsupported}
    func enableManualAccessibility(in app:Int)->Bool {false}
    func canSelectText(in element:Int)->Bool {state.withLock {$0.settable}}
    func textState(of element:Int)->AccessibleTextState? {
        state.withLock {value in
            guard value.readable else {return nil}
            if value.pendingReadbackCount>0 {
                value.pendingReadbackCount -= 1
                return value.pendingReadback
            }
            return value.text
        }
    }
    func select(_ range:NSRange,in element:Int)->Bool {
        state.withLock {value in
            value.selections.append(range)
            guard value.selectionWorks else {return false}
            let range=value.wrongSelection ? NSRange(location:0,length:0):range
            let before=value.text
            value.text = .init(value:value.text.value,selection:range,selectedText:(value.text.value as NSString).substring(with:range))
            value.pendingReadbackCount=value.selections.count==1 ? value.selectionReadbackDelay:value.restorationReadbackDelay
            switch value.readbackLag {
            case .snapshot:value.pendingReadback=before
            case .range:value.pendingReadback = .init(value:before.value,selection:before.selection,selectedText:value.text.selectedText)
            case .selectedText:value.pendingReadback = .init(value:before.value,selection:range,selectedText:before.selectedText)
            }
            if value.revokeAfterSelection {value.authorized=false}
            if value.changeFocusAfterSelection {value.focused=2}
            return true
        }
    }
    func post(_ replacement:String) -> Bool {
        state.withLock {value in
            value.posts += 1
            let text=(value.text.value as NSString).replacingCharacters(in:value.text.selection,with:replacement)
            value.text = .init(value:text,selection:NSRange(location:value.text.selection.location+replacement.utf16.count,length:0),selectedText:"")
            if value.revokeAfterPost {value.authorized=false}
            if value.mutateAfterPost {value.text = .init(value:"外部の編集",selection:NSRange(location:5,length:0),selectedText:"")}
            return true
        }
    }
}
private final class LastMomentFocusProbe:FocusProbe {
    let process=Mutex(Int32(1))
    func read(process:Int32) async -> FocusTarget {.init(id:.init(process:1,element:1),capability:.editable)}
    func replace(_ change:LocalizedTextReplacement,target:TargetID,authorize:@escaping @Sendable () async -> Bool,
                 emit:@escaping @Sendable () async -> Bool) async -> LocalizedReplacementOutcome {
        guard await authorize() else {return .stopped(issued:false)}
        // AXの照合が成功した直後、MainActorへ発行を返す前に前面アプリが変わる。
        process.withLock {$0=2}
        return await emit() ? .applied:.stopped(issued:false)
    }
}

struct LocalizedReplacementTests {
    @Test func reportsTheStageAndWaitCountWithoutTreatingSelectionAsPublication() async throws {
        for restoring in [false,true] {
            let (access,change)=fixture()
            access.state.withLock {if restoring {$0.restorationReadbackDelay=100} else {$0.selectionReadbackDelay=100}}
            let probe=NativeFocusProbe(access:access,waitForEdit:{})
            let target=try #require(await probe.read(process:1).id)
            let report=await probe.replaceReporting(change,target:target,authorize:{true},emit:{access.post(change.replacement)})
            #expect(report.outcome == .stopped(issued:restoring))
            #expect(report.diagnostic.stage == (restoring ? .restorationReadback:.selectionReadback))
            #expect(report.diagnostic.reason == .timeout && report.diagnostic.waits==5)
            #expect(report.diagnostic.issued==restoring)
        }
    }
    private let suffix=String(repeating:"残す文章",count:22)
    private func fixture()->(RangeAccess,LocalizedTextReplacement) {
        let text="既存の文章：前半、"+suffix+"元からある後ろの文"
        return (RangeAccess(text:text,caret:("既存の文章：前半、"+suffix).utf16.count),
                .init(expectedTail:"、"+suffix,replacement:"。",preservedSuffix:suffix))
    }
    private func run(_ access:RangeAccess,_ change:LocalizedTextReplacement,emit:Bool=true) async throws -> LocalizedReplacementOutcome {
        let probe=NativeFocusProbe(access:access,waitForAccessibility:{},waitForEdit:{})
        let target=try #require(await probe.read(process:1).id)
        return await probe.replace(change,target:target,authorize:{access.state.withLock {$0.authorized}},emit:{emit ? access.post(change.replacement):true})
    }
    @Test func changesOnlyTheMiddleAndRestoresTheOriginalInputPosition() async throws {
        let (access,change)=fixture()
        #expect(try await run(access,change) == .applied)
        let result=access.state.withLock {$0}
        #expect(result.text.value=="既存の文章：前半。"+suffix+"元からある後ろの文")
        #expect(result.text.selection==NSRange(location:("既存の文章：前半。"+suffix).utf16.count,length:0))
        #expect(result.posts==1 && result.selections.count==2 && result.selections.first?.length==1)
        #expect(result.capabilityReads>=6 && result.capabilityReads<15)
    }
    @Test func unsupportedFieldsDoNotChangeSelectionOrPostAnything() async throws {
        for unreadable in [false,true] {
            let (access,change)=fixture()
            access.state.withLock {if unreadable {$0.readable=false} else {$0.settable=false}}
            #expect(try await run(access,change) == .unavailable)
            #expect(access.state.withLock {$0.posts==0 && $0.selections.isEmpty})
        }
    }
    @Test func changedTextOrSelectionRejectsTheEditInsteadOfFallingBack() async throws {
        for selection in [false,true] {
            let (access,change)=fixture()
            access.state.withLock {$0.text = selection ? .init(value:$0.text.value,selection:NSRange(location:0,length:1),selectedText:"既"):.init(value:"違う文",selection:NSRange(location:3,length:0),selectedText:"")}
            #expect(try await run(access,change) == .stopped(issued:false))
            #expect(access.state.withLock {$0.posts==0 && $0.selections.isEmpty})
        }
    }
    @Test func cancellationTargetChangeAndWrongSelectionNeverPostOrRestore() async throws {
        for mode in 0..<4 {
            let (access,change)=fixture()
            access.state.withLock {
                $0.revokeAfterSelection=mode==0;$0.changeFocusAfterSelection=mode==1
                $0.wrongSelection=mode==2;$0.selectionWorks=mode != 3
            }
            #expect(try await run(access,change) == .stopped(issued:false))
            #expect(access.state.withLock {$0.posts==0 && $0.selections.count==1})
        }
    }
    @Test func cancellationOrExternalEditingAfterPublicationNeverMovesTheCaret() async throws {
        for cancel in [false,true] {
            let (access,change)=fixture()
            access.state.withLock {$0.revokeAfterPost=cancel;$0.mutateAfterPost = !cancel}
            #expect(try await run(access,change) == .stopped(issued:true))
            #expect(access.state.withLock {$0.posts==1 && $0.selections.count==1})
        }
    }
    @Test func unacknowledgedKeyEventStopsAfterBoundedReadbackWithoutRetyping() async throws {
        let (access,change)=fixture()
        #expect(try await run(access,change,emit:false) == .stopped(issued:true))
        #expect(access.state.withLock {$0.posts==0 && $0.selections.count==1 && $0.capabilityReads<15})
    }
    @Test func precedingInputMayFinishBeforeAnySelectionIsChanged() async throws {
        let (access,change)=fixture(),expected=access.state.withLock {$0.text}
        access.state.withLock {$0.text = .init(value:"既存の文章：",selection:NSRange(location:6,length:0),selectedText:"")}
        let waits=Mutex(0)
        let probe=NativeFocusProbe(access:access,waitForEdit:{
            waits.withLock {$0 += 1}
            access.state.withLock {$0.text=expected}
        })
        let target=try #require(await probe.read(process:1).id)
        let outcome=await probe.replace(change,target:target,authorize:{true},emit:{access.post(change.replacement)})
        #expect(outcome == .applied && waits.withLock {$0}==1)
        #expect(access.state.withLock {$0.posts==1 && $0.selections.count==2})
    }
    @Test func selectionReadbackMayLagBeforeTheReplacementIsIssued() async throws {
        for lag in RangeAccess.ReadbackLag.allCases {
            for delayedReads in [1,5] {
                let (access,change)=fixture(),waits=Mutex(0)
                access.state.withLock {$0.selectionReadbackDelay=delayedReads;$0.readbackLag=lag}
                let probe=NativeFocusProbe(access:access,waitForEdit:{waits.withLock {$0 += 1}})
                let target=try #require(await probe.read(process:1).id)
                let outcome=await probe.replace(change,target:target,authorize:{true},emit:{
                    #expect(access.state.withLock {$0.pendingReadbackCount==0})
                    return access.post(change.replacement)
                })
                #expect(outcome == .applied && waits.withLock {$0}==delayedReads)
                #expect(access.state.withLock {$0.posts==1 && $0.selections.count==2 && $0.text.selection.length==0})
                #expect(access.state.withLock {$0.text.value}=="既存の文章：前半。"+suffix+"元からある後ろの文")
            }
        }
    }
    @Test func restorationReadbackMayLagAfterTheReplacementIsIssued() async throws {
        for delayedReads in [1,5] {
            let (access,change)=fixture(),waits=Mutex(0),original=access.state.withLock {$0.text}
            access.state.withLock {$0.restorationReadbackDelay=delayedReads}
            let probe=NativeFocusProbe(access:access,waitForEdit:{waits.withLock {$0 += 1}})
            let target=try #require(await probe.read(process:1).id)
            let outcome=await probe.replace(change,target:target,authorize:{true},emit:{access.post(change.replacement)})
            #expect(outcome == .applied && waits.withLock {$0}==delayedReads)
            #expect(access.state.withLock {$0.posts==1 && $0.selections.count==2 && $0.text.selection==original.selection})
        }
    }
    @Test func selectionReadbackTimeoutNeverRepeatsSelectionOrTextPublication() async throws {
        for restoring in [false,true] {
            let (access,change)=fixture(),waits=Mutex(0)
            access.state.withLock {if restoring {$0.restorationReadbackDelay=100} else {$0.selectionReadbackDelay=100}}
            let probe=NativeFocusProbe(access:access,waitForEdit:{waits.withLock {$0 += 1}})
            let target=try #require(await probe.read(process:1).id)
            let outcome=await probe.replace(change,target:target,authorize:{true},emit:{access.post(change.replacement)})
            #expect(outcome == .stopped(issued:restoring) && waits.withLock {$0}==5)
            #expect(access.state.withLock {$0.posts==(restoring ? 1:0) && $0.selections.count==(restoring ? 2:1)})
        }
    }
    @Test func changedStateDuringSelectionReadbackStopsWithoutAnotherEdit() async throws {
        for restoring in [false,true] {
            for changeKind in 0..<7 {
                let (access,change)=fixture(),waits=Mutex(0)
                access.state.withLock {if restoring {$0.restorationReadbackDelay=1} else {$0.selectionReadbackDelay=1}}
                let probe=NativeFocusProbe(access:access,waitForEdit:{
                    waits.withLock {$0 += 1}
                    access.state.withLock {value in
                        switch changeKind {
                        case 0:value.authorized=false
                        case 1:value.focused=2
                        case 2:value.capability = .protected
                        case 3:value.readable=false
                        case 4:value.text = .init(value:"外部の編集",selection:NSRange(location:5,length:0),selectedText:"")
                        case 5:value.text = .init(value:value.text.value,selection:NSRange(location:0,length:1),selectedText:"既")
                        default:value.text = .init(value:value.text.value,selection:value.text.selection,selectedText:"別の選択")
                        }
                    }
                })
                let target=try #require(await probe.read(process:1).id)
                let outcome=await probe.replace(change,target:target,authorize:{access.state.withLock {$0.authorized}},emit:{access.post(change.replacement)})
                #expect(outcome == .stopped(issued:restoring) && waits.withLock {$0}==1)
                #expect(access.state.withLock {$0.posts==(restoring ? 1:0) && $0.selections.count==(restoring ? 2:1)})
            }
        }
    }
    @Test func cancellationDuringSelectionReadbackNeverResumesEditing() async throws {
        for restoring in [false,true] {
            for throwing in [false,true] {
                let (access,change)=fixture(),waits=Mutex(0)
                access.state.withLock {if restoring {$0.restorationReadbackDelay=1} else {$0.selectionReadbackDelay=1}}
                let probe=NativeFocusProbe(access:access,waitForEdit:{
                    waits.withLock {$0 += 1}
                    if throwing {throw CancellationError()}
                    withUnsafeCurrentTask {$0?.cancel()}
                })
                let target=try #require(await probe.read(process:1).id)
                let task=Task {await probe.replace(change,target:target,authorize:{true},emit:{access.post(change.replacement)})}
                let outcome=await task.value
                #expect(outcome == .stopped(issued:restoring) && waits.withLock {$0}==1)
                #expect(access.state.withLock {$0.posts==(restoring ? 1:0) && $0.selections.count==(restoring ? 2:1)})
            }
        }
    }
    @Test func changedCapabilityBeforeSelectionRejectsProtectedAndDisabledFields() async throws {
        for capability in [TargetCapability.protected,.noneditable,.unavailable] {
            let (access,change)=fixture(),probe=NativeFocusProbe(access:access,waitForEdit:{})
            let target=try #require(await probe.read(process:1).id)
            access.state.withLock {$0.capability=capability}
            let outcome=await probe.replace(change,target:target,authorize:{true},emit:{access.post(change.replacement)})
            #expect(outcome == .stopped(issued:false) && access.state.withLock {$0.posts==0 && $0.selections.isEmpty})
        }
    }
    @MainActor @Test func focusServiceConnectsEpochChecksAndTheRangeTransaction() async throws {
        let (access,change)=fixture(),probe=NativeFocusProbe(access:access,waitForEdit:{})
        let focus=AXFocusService(probe:probe,process:{1},clock:MonotonicSessionClock())
        let snapshot=await focus.read(),target=try #require(snapshot.target.id)
        let context=InjectionContext(session:SessionID(),epoch:snapshot.epoch,target:target)
        let result=await focus.replace(change,context:context,permit:{true},emit:{access.post(change.replacement)})
        #expect(result == .applied)
        focus.invalidate()
        let rejected=await focus.replace(change,context:context,permit:{true},emit:{access.post(change.replacement)})
        #expect(rejected == .stopped(issued:false) && access.state.withLock {$0.posts==1})
        await focus.stop()
    }
    @MainActor @Test func appChangeAfterAXVerificationStillRejectsTheFinalKeyEvent() async throws {
        let probe=LastMomentFocusProbe(),focus=AXFocusService(probe:probe,process:{probe.process.withLock {$0}},clock:MonotonicSessionClock())
        let snapshot=await focus.read(),target=try #require(snapshot.target.id)
        var posts=0
        let outcome=await focus.replace(fixture().1,context:.init(session:SessionID(),epoch:snapshot.epoch,target:target),permit:{true},emit:{posts += 1;return true})
        #expect(outcome == .stopped(issued:false) && posts==0)
        await focus.stop()
    }
    @Test func utf16PlanPreservesEmojiAndRejectsAnInteriorGraphemeBoundary() throws {
        let tail=String(repeating:"👨‍👩‍👧‍👦が🇯🇵",count:12),before="元の文🙂"
        for (old,new) in [("、",""),("","。"),("👨‍👩‍👧‍👦","🙂")] {
            let original=before+old+tail+"後ろ"
            let plan=try #require(LocalizedTextPlan(change:.init(expectedTail:old+tail,replacement:new,preservedSuffix:tail),state:.init(value:original,selection:NSRange(location:(before+old+tail).utf16.count,length:0),selectedText:"")))
            #expect(plan.restored.value==before+new+tail+"後ろ")
            #expect(plan.restored.selection.location==(before+new+tail).utf16.count)
        }
        let split="か\u{3099}"+tail
        #expect(LocalizedTextPlan(change:.init(expectedTail:"\u{3099}"+tail,replacement:"。",preservedSuffix:tail),state:.init(value:split,selection:NSRange(location:split.utf16.count,length:0),selectedText:""))==nil)
        let maximum=String(repeating:"あ",count:LocalizedTextPlan.maximumUTF16-tail.utf16.count)+tail
        #expect(LocalizedTextPlan(change:.init(expectedTail:tail,replacement:"追加",preservedSuffix:tail),state:.init(value:maximum,selection:NSRange(location:maximum.utf16.count,length:0),selectedText:""))==nil)
    }
}
