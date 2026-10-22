import Testing
import Synchronization
import ForblazeCore
import ForblazeApplication
import ForblazeTestSupport
@testable import ForblazeMacOS

private final class FakeFocusAccess: FocusAccessibilityAccess {
    typealias Element = Int
    struct State {
        var capabilities:[TargetCapability] = []
        var manual:ManualAccessibilityState = .disabled
        var enableSucceeds=true
        var reads=0
        var missingReads:Set<Int> = []
        var manualChecks=0
        var writes=0
        var roleReads=0
        var roleStatus:Int32=0
    }
    let state:Mutex<State>
    let onRead:@Sendable (Int)->Void
    init(_ state:State,onRead:@escaping @Sendable (Int)->Void={_ in}) {self.state=Mutex(state);self.onRead=onRead}
    func application(process:Int32)->Int {Int(process)}
    func queryApplicationRole(in app:Int)->Int32 {
        state.withLock {$0.roleReads += 1;return $0.roleStatus}
    }
    func focusedElement(in app:Int)->Int? {
        let result=state.withLock {value in
            value.reads += 1
            return (value.reads,value.missingReads.contains(value.reads) ? nil:value.reads)
        }
        onRead(result.0);return result.1
    }
    func capability(of element:Int)->TargetCapability {
        state.withLock {value in value.capabilities[min(element-1,value.capabilities.count-1)]}
    }
    func elementsEqual(_ lhs:Int,_ rhs:Int)->Bool {true}
    func manualAccessibility(in app:Int)->ManualAccessibilityState {
        state.withLock {value in value.manualChecks += 1;return value.manual}
    }
    func enableManualAccessibility(in app:Int)->Bool {
        state.withLock {value in
            value.writes += 1
            if value.enableSucceeds {value.manual = .enabled}
            return value.enableSucceeds
        }
    }
}

struct FocusRecoveryTests {
    @Test func preparationRecoversEvenWhenManualAccessibilityIsUnsupported() async {
        let access=FakeFocusAccess(.init(capabilities:[.unavailable,.editable],manual:.unsupported))
        let probe=NativeFocusProbe(access:access,waitForAccessibility:{})
        let result=await probe.prepare(process:1,isCurrent:{true})
        #expect(result.permitsInput)
        #expect(access.state.withLock {$0.roleReads==1 && $0.writes==0})
    }

    @Test func ordinaryReadsNeverAttemptRecovery() async {
        let access=FakeFocusAccess(.init(capabilities:[.unavailable,.editable]))
        let probe=NativeFocusProbe(access:access,waitForAccessibility:{})
        #expect(await probe.read(process:1).inputIssue == .unavailable)
        #expect(access.state.withLock {$0.reads==1 && $0.roleReads==0 && $0.manualChecks==0 && $0.writes==0})
    }

    @Test func preparationDoesNotRecoverAnExpiredRequest() async {
        let access=FakeFocusAccess(.init(capabilities:[.unavailable,.editable]))
        let probe=NativeFocusProbe(access:access,waitForAccessibility:{})
        #expect(await probe.prepare(process:1,isCurrent:{false}).inputIssue == .unavailable)
        #expect(access.state.withLock {$0.roleReads==0 && $0.writes==0})
    }

    @Test(arguments:[TargetCapability.editable,.protected,.noneditable])
    func knownTargetsDoNotChangeAccessibility(capability:TargetCapability) async {
        let access=FakeFocusAccess(.init(capabilities:[capability]))
        let probe=NativeFocusProbe(access:access,waitForAccessibility:{})
        let result=await probe.prepare(process:1,isCurrent:{true})
        #expect(result.capability==capability)
        #expect(access.state.withLock {$0.manualChecks==0 && $0.writes==0 && $0.roleReads==0 && $0.reads==1})
    }

    @Test func unavailableTargetEnablesSupportedAccessibilityAndWaitsForTree() async {
        let access=FakeFocusAccess(.init(capabilities:[.unavailable,.unavailable,.editable]))
        let waits=Mutex(0)
        let probe=NativeFocusProbe(access:access,waitForAccessibility:{waits.withLock {$0 += 1}})
        let result=await probe.prepare(process:1,isCurrent:{true})
        #expect(result.permitsInput)
        #expect(access.state.withLock {$0.writes==1 && $0.reads==3})
        #expect(waits.withLock {$0}==2)
    }

    @Test func alreadyEnabledAccessibilityIsNotWrittenAgain() async {
        let access=FakeFocusAccess(.init(capabilities:[.unavailable,.editable],manual:.enabled))
        let probe=NativeFocusProbe(access:access,waitForAccessibility:{})
        #expect(await probe.prepare(process:1,isCurrent:{true}).permitsInput)
        #expect(access.state.withLock {$0.writes==0})
    }

    @Test func absentFocusedElementCanRecoverAndKeepTheSameTargetIdentity() async {
        let access=FakeFocusAccess(.init(capabilities:[.editable],missingReads:[1]))
        let probe=NativeFocusProbe(access:access,waitForAccessibility:{})
        let first=await probe.prepare(process:1,isCurrent:{true}),second=await probe.prepare(process:1,isCurrent:{true})
        #expect(first.permitsInput && second.permitsInput && first.id==second.id)
        #expect(access.state.withLock {$0.writes==1 && $0.manualChecks==1 && $0.reads==3})
    }

    @Test func unsupportedManualAttributeStillHasBoundedRoleRecovery() async {
        let access=FakeFocusAccess(.init(capabilities:[.unavailable],manual:.unsupported))
        let probe=NativeFocusProbe(access:access,waitForAccessibility:{})
        #expect(await probe.prepare(process:1,isCurrent:{true}).inputIssue == .unavailable)
        #expect(access.state.withLock {$0.writes==0 && $0.roleReads==1 && $0.reads==31})
    }

    @Test func failedLegacyEnableStillBoundsRoleRecovery() async {
        let access=FakeFocusAccess(.init(capabilities:[.unavailable],enableSucceeds:false))
        let probe=NativeFocusProbe(access:access,waitForAccessibility:{})
        #expect(await probe.prepare(process:1,isCurrent:{true}).inputIssue == .unavailable)
        #expect(access.state.withLock {$0.writes==1 && $0.reads==31})
    }

    @Test(arguments:[TargetCapability.protected,.noneditable])
    func recoveredTargetStillRequiresAnEditableField(capability:TargetCapability) async {
        let access=FakeFocusAccess(.init(capabilities:[.unavailable,capability]))
        let probe=NativeFocusProbe(access:access,waitForAccessibility:{})
        let result=await probe.prepare(process:1,isCurrent:{true})
        #expect(result.capability==capability && !result.permitsInput)
        #expect(access.state.withLock {$0.reads==2})
    }

    @Test func persistentFailureHasBoundedRetries() async {
        let access=FakeFocusAccess(.init(capabilities:[.unavailable]))
        let probe=NativeFocusProbe(access:access,waitForAccessibility:{})
        #expect(await probe.prepare(process:1,isCurrent:{true}).inputIssue == .unavailable)
        #expect(access.state.withLock {$0.writes==1 && $0.reads==31})
    }

    @Test func cancellationDuringTreePreparationDoesNotRetry() async {
        let access=FakeFocusAccess(.init(capabilities:[.unavailable,.editable]))
        let probe=NativeFocusProbe(access:access,waitForAccessibility:{throw CancellationError()})
        #expect(await probe.prepare(process:1,isCurrent:{true}).inputIssue == .unavailable)
        #expect(access.state.withLock {$0.reads==1})
    }

    @Test func recoveryLogsBeforeAndAfterWithMatchingAttemptAndActualResult() async {
        let access=FakeFocusAccess(.init(capabilities:[.unavailable,.unavailable,.editable],manual:.unsupported))
        let records=Mutex<[FocusRecoveryDiagnostic]>([])
        let probe=NativeFocusProbe(access:access,waitForAccessibility:{},reportRecovery:{record in records.withLock {$0.append(record)}})
        #expect(await probe.prepare(process:1,isCurrent:{true}).permitsInput)
        let entries=records.withLock {$0}
        #expect(entries.count==2 && entries.first?.attempt==entries.last?.attempt)
        #expect(entries.first?.phase == .before && entries.first?.capability == .unavailable && entries.first?.outcome == .started)
        #expect(entries.last?.phase == .after && entries.last?.capability == .editable && entries.last?.outcome == .recovered)
        #expect(entries.last?.roleQueryStatus==0 && entries.last?.manual == .unsupported && entries.last?.retries==2)
    }

    @Test(arguments:[TargetCapability.editable,.noneditable,.protected])
    func knownFieldsNeverWaitOrLogRecovery(capability:TargetCapability) async {
        let access=FakeFocusAccess(.init(capabilities:[capability]))
        let counts=Mutex((waits:0,reports:0))
        let probe=NativeFocusProbe(access:access,waitForAccessibility:{counts.withLock {$0.waits += 1}},
                                   reportRecovery:{_ in counts.withLock {$0.reports += 1}})
        #expect(await probe.prepare(process:1,isCurrent:{true}).capability==capability)
        #expect(counts.withLock {$0.waits==0 && $0.reports==0})
    }

    @Test func recoveryDeadlineStopsBeforeTheNextAXQuery() async {
        let access=FakeFocusAccess(.init(capabilities:[.unavailable,.editable],manual:.unsupported))
        let instant=Mutex(ContinuousClock.now),records=Mutex<[FocusRecoveryDiagnostic]>([])
        let probe=NativeFocusProbe(access:access,waitForAccessibility:{instant.withLock {$0=$0.advanced(by:.seconds(3))}},
                                   recoveryNow:{instant.withLock {$0}},reportRecovery:{record in records.withLock {$0.append(record)}})
        #expect(await probe.prepare(process:1,isCurrent:{true}).inputIssue == .unavailable)
        #expect(access.state.withLock {$0.reads==1})
        #expect(records.withLock {$0.last?.outcome == .timedOut && $0.last?.milliseconds==3000})
    }

    @Test func recoveryDeadlineIncludesSlowAXQueriesAndRejectsLateSuccess() async {
        let instant=Mutex(ContinuousClock.now),records=Mutex<[FocusRecoveryDiagnostic]>([])
        let access=FakeFocusAccess(.init(capabilities:[.unavailable,.editable],manual:.unsupported),onRead:{count in
            if count==2 {instant.withLock {$0=$0.advanced(by:.seconds(3))}}
        })
        let probe=NativeFocusProbe(access:access,waitForAccessibility:{},recoveryNow:{instant.withLock {$0}},
                                   reportRecovery:{record in records.withLock {$0.append(record)}})
        #expect(await probe.prepare(process:1,isCurrent:{true}).inputIssue == .unavailable)
        #expect(access.state.withLock {$0.reads==2})
        #expect(records.withLock {$0.last?.outcome == .timedOut && $0.last?.capability == .editable})
    }

    @Test func changingTargetWhileWaitingStopsWithoutReadingNewField() async {
        let access=FakeFocusAccess(.init(capabilities:[.unavailable,.editable],manual:.unsupported))
        let current=Mutex(true),records=Mutex<[FocusRecoveryDiagnostic]>([])
        let probe=NativeFocusProbe(access:access,waitForAccessibility:{current.withLock {$0=false}},
                                   reportRecovery:{record in records.withLock {$0.append(record)}})
        #expect(await probe.prepare(process:1,isCurrent:{current.withLock {$0}}).inputIssue == .unavailable)
        #expect(access.state.withLock {$0.reads==1})
        #expect(records.withLock {$0.last?.outcome == .invalidated})
    }

    @Test func taskCancellationProducesAnAfterRecordAndNeverRecovers() async {
        let access=FakeFocusAccess(.init(capabilities:[.unavailable,.editable],manual:.unsupported))
        let started=ControlledGate<Bool>(),release=ControlledGate<Bool>(),records=Mutex<[FocusRecoveryDiagnostic]>([])
        let probe=NativeFocusProbe(access:access,waitForAccessibility:{await started.send(true);_=await release.next()},
                                   reportRecovery:{record in records.withLock {$0.append(record)}})
        let task=Task {await probe.prepare(process:1,isCurrent:{true})}
        _=await started.next();task.cancel();await release.send(true)
        #expect(await task.value.inputIssue == .unavailable)
        #expect(access.state.withLock {$0.reads==1})
        #expect(records.withLock {$0.count==2 && $0.last?.outcome == .cancelled})
    }

    @Test func unsupportedQueriesStopAndRecordTheAPIError() async {
        let access=FakeFocusAccess(.init(capabilities:[.unavailable],manual:.unsupported,roleStatus:-25205))
        let records=Mutex<[FocusRecoveryDiagnostic]>([])
        let probe=NativeFocusProbe(access:access,waitForAccessibility:{},reportRecovery:{record in records.withLock {$0.append(record)}})
        #expect(await probe.prepare(process:1,isCurrent:{true}).inputIssue == .unavailable)
        #expect(access.state.withLock {$0.reads==1 && $0.writes==0})
        #expect(records.withLock {$0.last?.outcome == .unavailable && $0.last?.roleQueryStatus == -25205})
    }

    @Test(arguments:[TargetCapability.noneditable,.protected])
    func recoveredRejectedFieldIsLoggedWithoutContinuing(capability:TargetCapability) async {
        let access=FakeFocusAccess(.init(capabilities:[.unavailable,capability],manual:.unsupported))
        let records=Mutex<[FocusRecoveryDiagnostic]>([])
        let probe=NativeFocusProbe(access:access,waitForAccessibility:{},reportRecovery:{record in records.withLock {$0.append(record)}})
        #expect(await probe.prepare(process:1,isCurrent:{true}).capability==capability)
        #expect(access.state.withLock {$0.reads==2})
        #expect(records.withLock {$0.last?.outcome == .rejected && $0.last?.capability == .init(capability)})
    }
}
