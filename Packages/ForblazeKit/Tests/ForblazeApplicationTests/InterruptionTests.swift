import Testing
import ForblazeCore
import ForblazeApplication
@MainActor private final class LoginFake:LoginItemService {
    var status:LoginItemStatus = .disabled
    var calls:[Bool]=[]
    var fails=false
    func setEnabled(_ enabled:Bool) async throws {
        calls.append(enabled)
        if fails {throw LoginItemFailure.registration}
        status=enabled ? .enabled:.disabled
    }
}
@MainActor struct InterruptionTests {
    @Test func interruptionsCloseInputAndResumeNeverStartsRecording() async throws {
        for event in [SystemInterruption.locked,.sleep,.audioChanged,.permissionsLost,.tapDisabled,.quit] {
            let speech=FakeSpeech(),trigger=FakeTrigger(),session=SessionCoordinator(speech:speech,clock:FakeClock())
            session.toggle();await session.awaitPreparation()
            let c=InterruptionCoordinator(session:session,trigger:trigger);var resumes=0;c.onResume={resumes += 1}
            c.handle(event)
            #expect(session.state.permission == .closed)
            await session.awaitCleanup();#expect(session.state.phase == .idle)
            let count=speech.calls.filter{$0=="start"}.count
            c.handle(.resumed)
            #expect(session.state.phase == .idle && speech.calls.filter{$0=="start"}.count==count)
            #expect(resumes>=1)
        }
    }
    @Test func loginSettingIsExplicitAndFailureIsNotSuccess() async {
        let service=LoginFake()
        #expect(service.status == .disabled)
        let actual=LoginItemCoordinator(service:service)
        #expect(service.calls.isEmpty)
        actual.setEnabled(true);await actual.awaitIdle()
        #expect(actual.status == .enabled && service.calls==[true])
        service.fails=true;actual.setEnabled(false);await actual.awaitIdle()
        #expect(actual.status == .enabled && actual.error == .registration)
        service.fails=false;actual.setEnabled(false);await actual.awaitIdle()
        #expect(actual.status == .disabled && actual.error==nil)
        await actual.shutdown()
    }
}
