import Testing
import ApplicationServices
import ForblazeCore
import ForblazeApplication
import ForblazeTestSupport
@testable import ForblazeMacOS
private actor DelayedFocusProbe: FocusProbe {
    private(set) var calls=0
    let started=ControlledGate<Bool>()
    let replies=ControlledGate<FocusTarget>()
    func read(process:Int32) async -> FocusTarget {calls += 1;await started.send(true);return await replies.next()}
}
@MainActor private final class NoFocusClock:SessionClock {
    func sleep(for duration:Duration) async throws {throw CancellationError()}
}
@MainActor struct FocusServiceTests {
    @Test func cancelledPreparationCannotAcceptALateEditableReply() async {
        let probe=DelayedFocusProbe()
        let preparing=AXFocusService(probe:probe,process:{1},clock:NoFocusClock())
        let task=Task {await preparing.prepare()};_=await probe.started.next()
        task.cancel()
        await probe.replies.send(.init(id:.init(process:1,element:1),capability:.editable))
        #expect(await task.value.target.permitsInput==false)
        await preparing.stop()
    }

    @Test func preparationRejectsAppOrSpaceChangesEvenIfTheAppReturns() async {
        let probe=DelayedFocusProbe()
        var process:Int32=1
        let focus=AXFocusService(probe:probe,process:{process},clock:NoFocusClock())
        let task=Task {await focus.prepare()};_=await probe.started.next()
        process=2;focus.invalidate();process=1
        await probe.replies.send(.init(id:.init(process:1,element:1),capability:.editable))
        let snapshot=await task.value
        #expect(!snapshot.target.permitsInput && snapshot.invalidation == .changed)
        await focus.stop()
    }

    @Test func missingAXRoleIsUnknownWhileProtectedAndDisabledFieldsKeepTheirReason() {
        #expect(FocusCapability.classify(role:nil,subrole:nil,enabled:nil) == .unavailable)
        #expect(FocusCapability.classify(role:nil,subrole:kAXSecureTextFieldSubrole,enabled:false) == .protected)
        #expect(FocusCapability.classify(role:kAXTextAreaRole,subrole:nil,enabled:false) == .noneditable)
        #expect(FocusCapability.classify(role:kAXButtonRole,subrole:nil,enabled:true) == .noneditable)
        #expect(FocusCapability.classify(role:kAXTextAreaRole,subrole:nil,enabled:true) == .editable)
    }

    @Test func knownAppOrSpaceChangeIsDifferentFromUnavailableAXResponse() async {
        let probe=DelayedFocusProbe(),focus=AXFocusService(probe:DelayedFocusProbe(),process:{1},clock:NoFocusClock())
        var change:FocusSnapshot?
        focus.onChange={change=$0}
        focus.invalidate()
        #expect(change?.invalidation == .changed)
        #expect(change?.target.permitsInput==false)
        let missing=AXFocusService(probe:probe,process:{1},clock:NoFocusClock())
        let task=Task {await missing.read()};_=await probe.started.next()
        await probe.replies.send(.init(id:nil,capability:.unavailable))
        let snapshot=await task.value
        #expect(snapshot.invalidation==nil && snapshot.target.inputIssue == .unavailable)
        await focus.stop();await missing.stop()
    }

    @Test func concurrentChecksShareOneAXQuery() async {
        let probe=DelayedFocusProbe()
        let actual=AXFocusService(probe:probe,process:{1},clock:NoFocusClock())
        let first=Task {await actual.read()};_=await probe.started.next()
        let second=Task(priority:.high) {await actual.read()}
        await Task.yield()
        let value=FocusTarget(id:.init(process:1,element:1),capability:.editable)
        await probe.replies.send(value);await probe.replies.send(value)
        let a=await first.value,b=await second.value
        #expect(a.target.permitsInput && b.target.permitsInput && a.epoch==b.epoch)
        #expect(await probe.calls==1)
        await actual.stop()
    }
    @Test func oldAXReplyCannotRestoreInvalidatedFocus() async {
        let probe=DelayedFocusProbe()
        // 別サービスの応答を混ぜず、問い合わせ中に世代を無効化する。
        let focus=AXFocusService(probe:probe,process:{1},clock:NoFocusClock())
        let task=Task {await focus.read()};_=await probe.started.next()
        focus.invalidate()
        await probe.replies.send(.init(id:.init(process:1,element:1),capability:.editable))
        let stale=await task.value
        #expect(!stale.target.permitsInput && stale.epoch.value==1)
        await focus.stop()
    }
}
