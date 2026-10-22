import AppKit
import ApplicationServices
import ForblazeCore
import ForblazeApplication
protocol FocusProbe: Sendable {
    func read(process: Int32) async -> FocusTarget
    func prepare(process:Int32,isCurrent:@escaping @Sendable () async -> Bool) async -> FocusTarget
    func replace(_ change:LocalizedTextReplacement,target:TargetID,
                 authorize:@escaping @Sendable () async -> Bool,
                 emit:@escaping @Sendable () async -> Bool) async -> LocalizedReplacementOutcome
    func replaceReporting(_ change:LocalizedTextReplacement,target:TargetID,
                          authorize:@escaping @Sendable () async -> Bool,
                          emit:@escaping @Sendable () async -> Bool) async -> LocalizedReplacementReport
}
extension FocusProbe {
    func prepare(process:Int32,isCurrent:@escaping @Sendable () async -> Bool) async -> FocusTarget {await read(process:process)}
    func replace(_ change:LocalizedTextReplacement,target:TargetID,authorize:@escaping @Sendable () async -> Bool,
                 emit:@escaping @Sendable () async -> Bool) async -> LocalizedReplacementOutcome {.unavailable}
    func replaceReporting(_ change:LocalizedTextReplacement,target:TargetID,authorize:@escaping @Sendable () async -> Bool,
                          emit:@escaping @Sendable () async -> Bool) async -> LocalizedReplacementReport {
        .init(await replace(change,target:target,authorize:authorize,emit:emit))
    }
}
enum FocusCapability {
    static func classify(role:String?,subrole:String?,enabled:Bool?) -> TargetCapability {
        if subrole==kAXSecureTextFieldSubrole {return .protected}
        if enabled==false {return .noneditable}
        guard let role else {return .unavailable}
        guard role==kAXTextFieldRole || role==kAXTextAreaRole || role==kAXComboBoxRole else {return .noneditable}
        return .editable
    }
}
enum ManualAccessibilityState: Sendable {case unsupported,disabled,enabled}
/// AXへのアクセスを差し替え、情報公開前後の取得と拒否条件を検証する。
protocol FocusAccessibilityAccess: Sendable {
    associatedtype Element
    func application(process:Int32)->Element
    func queryApplicationRole(in app:Element)->Int32
    func focusedElement(in app:Element)->Element?
    func capability(of element:Element)->TargetCapability
    func elementsEqual(_ lhs:Element,_ rhs:Element)->Bool
    func manualAccessibility(in app:Element)->ManualAccessibilityState
    func enableManualAccessibility(in app:Element)->Bool
    func canSelectText(in element:Element)->Bool
    func textState(of element:Element)->AccessibleTextState?
    func select(_ range:NSRange,in element:Element)->Bool
}
extension FocusAccessibilityAccess {
    func queryApplicationRole(in app:Element)->Int32 {AXError.notImplemented.rawValue}
    func canSelectText(in element:Element)->Bool {false}
    func textState(of element:Element)->AccessibleTextState? {nil}
    func select(_ range:NSRange,in element:Element)->Bool {false}
}
private struct NativeFocusAccessibilityAccess: FocusAccessibilityAccess {
    private static var manualAttribute:CFString {"AXManualAccessibility" as CFString}
    private func string(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,name as CFString,&value) == .success else {return nil}
        return value as? String
    }
    func application(process:Int32)->AXUIElement {
        let app=AXUIElementCreateApplication(process)
        AXUIElementSetMessagingTimeout(app,0.15)
        return app
    }
    func queryApplicationRole(in app:AXUIElement)->Int32 {
        var role:CFTypeRef?
        return AXUIElementCopyAttributeValue(app,kAXRoleAttribute as CFString,&role).rawValue
    }
    func focusedElement(in app:AXUIElement)->AXUIElement? {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app,kAXFocusedUIElementAttribute as CFString,&focused) == .success,
              let focused,CFGetTypeID(focused)==AXUIElementGetTypeID() else {return nil}
        let element=unsafeDowncast(focused,to:AXUIElement.self)
        AXUIElementSetMessagingTimeout(element,0.15)
        return element
    }
    func capability(of element:AXUIElement)->TargetCapability {
        var values:CFArray?
        let names=[kAXRoleAttribute,kAXSubroleAttribute,kAXEnabledAttribute] as CFArray
        if AXUIElementCopyMultipleAttributeValues(element,names,[],&values) == .success,
           let values=values as? [Any],values.count==3 {
            return FocusCapability.classify(role:values[0] as? String,subrole:values[1] as? String,enabled:values[2] as? Bool)
        }
        // 一括取得を実装していない入力先でも、従来の確認を省略しない。
        let role=string(element,kAXRoleAttribute),subrole=string(element,kAXSubroleAttribute)
        var enabled:CFTypeRef?
        let status=AXUIElementCopyAttributeValue(element,kAXEnabledAttribute as CFString,&enabled)
        return FocusCapability.classify(role:role,subrole:subrole,enabled:status == .success ? enabled as? Bool:nil)
    }
    func elementsEqual(_ lhs:AXUIElement,_ rhs:AXUIElement)->Bool {CFEqual(lhs,rhs)}
    func manualAccessibility(in app:AXUIElement)->ManualAccessibilityState {
        var settable:DarwinBoolean=false
        guard AXUIElementIsAttributeSettable(app,Self.manualAttribute,&settable) == .success,settable.boolValue else {return .unsupported}
        var value:CFTypeRef?
        guard AXUIElementCopyAttributeValue(app,Self.manualAttribute,&value) == .success,
              let enabled=value as? Bool else {return .unsupported}
        return enabled ? .enabled:.disabled
    }
    func enableManualAccessibility(in app:AXUIElement)->Bool {
        AXUIElementSetAttributeValue(app,Self.manualAttribute,kCFBooleanTrue) == .success
    }
    func canSelectText(in element:AXUIElement)->Bool {
        var settable:DarwinBoolean=false
        return AXUIElementIsAttributeSettable(element,kAXSelectedTextRangeAttribute as CFString,&settable) == .success && settable.boolValue
    }
    func textState(of element:AXUIElement)->AccessibleTextState? {
        var count:CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,kAXNumberOfCharactersAttribute as CFString,&count) == .success,
              let count=count as? Int,count>=0,count<=LocalizedTextPlan.maximumUTF16 else {return nil}
        var values:CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element,[kAXValueAttribute,kAXSelectedTextRangeAttribute,kAXSelectedTextAttribute] as CFArray,[],&values) == .success,
              let values=values as? [Any],values.count==3,let text=values[0] as? String,
              text.utf16.count==count,CFGetTypeID(values[1] as CFTypeRef)==AXValueGetTypeID(),let selectedText=values[2] as? String else {return nil}
        let axRange=unsafeDowncast(values[1] as AnyObject,to:AXValue.self)
        var range=CFRange()
        guard AXValueGetType(axRange) == .cfRange,AXValueGetValue(axRange,.cfRange,&range),
              range.location>=0,range.length>=0,range.location<=count,range.length<=count-range.location else {return nil}
        return .init(value:text,selection:NSRange(location:range.location,length:range.length),selectedText:selectedText)
    }
    func select(_ range:NSRange,in element:AXUIElement)->Bool {
        var range=CFRange(location:range.location,length:range.length)
        guard let value=AXValueCreate(.cfRange,&range) else {return false}
        return AXUIElementSetAttributeValue(element,kAXSelectedTextRangeAttribute as CFString,value) == .success
    }
}
/// AXの実体と同期問い合わせはこのactorだけが所有する。
actor NativeFocusProbe<Access:FocusAccessibilityAccess>: FocusProbe {
    private let access:Access
    private let waitForAccessibility:@Sendable () async throws -> Void
    private let waitForEdit:@Sendable () async throws -> Void
    private let recoveryNow:@Sendable () -> ContinuousClock.Instant
    private let reportRecovery:@Sendable (FocusRecoveryDiagnostic) async -> Void
    private var previous:Access.Element?
    private var process:Int32=0
    private var identity:UInt64=0
    private var editing=false
    init(access:Access,waitForAccessibility:@escaping @Sendable () async throws -> Void={try await Task.sleep(for:.milliseconds(100))},
         waitForEdit:@escaping @Sendable () async throws -> Void={try await Task.sleep(for:.milliseconds(10))},
         recoveryNow:@escaping @Sendable () -> ContinuousClock.Instant={.now},
         reportRecovery:@escaping @Sendable (FocusRecoveryDiagnostic) async -> Void={_ in}) {
        self.access=access;self.waitForAccessibility=waitForAccessibility;self.waitForEdit=waitForEdit
        self.recoveryNow=recoveryNow;self.reportRecovery=reportRecovery
    }
    func read(process:Int32) async -> FocusTarget {
        guard process>0,!Task.isCancelled else {return .init(id:nil,capability:.unavailable)}
        let app=access.application(process:process)
        let element=access.focusedElement(in:app)
        return target(element:element,capability:element.map {access.capability(of:$0)} ?? .unavailable,process:process)
    }
    func prepare(process:Int32,isCurrent:@escaping @Sendable () async -> Bool) async -> FocusTarget {
        let unavailable=FocusTarget(id:nil,capability:.unavailable)
        guard process>0,!Task.isCancelled,await isCurrent(),!Task.isCancelled else {return unavailable}
        let app=access.application(process:process)
        var element=access.focusedElement(in:app)
        var capability=element.map {access.capability(of:$0)} ?? .unavailable
        guard capability == .unavailable else {return target(element:element,capability:capability,process:process)}
        let attempt=UUID(),started=recoveryNow(),deadline=started.advanced(by:.seconds(3))
        var roleStatus:Int32?,manual=FocusRecoveryDiagnostic.Manual.notAttempted,retries=0
        await reportRecovery(.init(attempt:attempt,phase:.before,capability:capability,outcome:.started))
        func interruption() async -> FocusRecoveryDiagnostic.Outcome? {
            if Task.isCancelled {return .cancelled}
            if !(await isCurrent()) {return .invalidated}
            return Task.isCancelled ? .cancelled:nil
        }
        func finish(_ outcome:FocusRecoveryDiagnostic.Outcome) async -> FocusTarget {
            let elapsed=started.duration(to:recoveryNow()).components
            await reportRecovery(.init(attempt:attempt,phase:.after,capability:capability,outcome:outcome,
                                       roleQueryStatus:roleStatus,manual:manual,retries:retries,
                                       milliseconds:Double(elapsed.seconds)*1000+Double(elapsed.attoseconds)/1e15))
            guard outcome == .recovered || outcome == .rejected else {return unavailable}
            return target(element:element,capability:capability,process:process)
        }
        if let reason=await interruption() {return await finish(reason)}
        // 役割の照会でAX情報の公開を始めるアプリにも対応する。設定値は変更しない。
        roleStatus=access.queryApplicationRole(in:app)
        if let reason=await interruption() {return await finish(reason)}
        switch access.manualAccessibility(in:app) {
        case .unsupported:manual = .unsupported
        case .enabled:manual = .alreadyEnabled
        case .disabled:
            if let reason=await interruption() {return await finish(reason)}
            manual=access.enableManualAccessibility(in:app) ? .enabled:.failed
        }
        if let reason=await interruption() {return await finish(reason)}
        if roleStatus != 0,manual == .unsupported || manual == .failed {return await finish(.unavailable)}
        // 開始時だけ、100ms間隔・30回・3秒を上限に再取得する。期限は問い合わせ後も確認する。
        for _ in 0..<30 {
            if recoveryNow()>=deadline {return await finish(.timedOut)}
            do {try await waitForAccessibility()} catch {return await finish(.cancelled)}
            if let reason=await interruption() {return await finish(reason)}
            if recoveryNow()>=deadline {return await finish(.timedOut)}
            element=access.focusedElement(in:app);retries += 1
            capability=element.map {access.capability(of:$0)} ?? .unavailable
            if let reason=await interruption() {return await finish(reason)}
            if recoveryNow()>=deadline {return await finish(.timedOut)}
            if capability != .unavailable {return await finish(capability == .editable ? .recovered:.rejected)}
        }
        return await finish(.timedOut)
    }
    private func target(element:Access.Element?,capability:TargetCapability,process:Int32)->FocusTarget {
        guard let element,!Task.isCancelled else {return .init(id:nil,capability:.unavailable)}
        let sameProcess=self.process == process
        var sameElement=false
        if let previous {sameElement=access.elementsEqual(previous,element)}
        if !sameProcess || !sameElement {identity += 1;previous=element;self.process=process}
        let id=TargetID(process:process,element:identity)
        // AXが確認できない欄を互換入力へ自動昇格しない。
        return .init(id:id,capability:capability)
    }
    // editingで一つの置換だけが所有する。AX照合と同じactorからのみ更新する。
    private struct EditProgress {
        var stage=LocalizedEditDiagnostic.Stage.validation
        var reason=LocalizedEditDiagnostic.Reason.none
        var waits=0
        var issued=false
    }
    private var editProgress=EditProgress()
    func replace(_ change:LocalizedTextReplacement,target:TargetID,authorize:@escaping @Sendable () async -> Bool,
                 emit:@escaping @Sendable () async -> Bool) async -> LocalizedReplacementOutcome {
        await replaceReporting(change,target:target,authorize:authorize,emit:emit).outcome
    }
    func replaceReporting(_ change:LocalizedTextReplacement,target:TargetID,authorize:@escaping @Sendable () async -> Bool,
                          emit:@escaping @Sendable () async -> Bool) async -> LocalizedReplacementReport {
        guard !editing else {return .init(.stopped(issued:false),diagnostic:.init(stage:.validation,reason:.busy))}
        editing=true;defer {editing=false}
        editProgress = .init()
        func report(_ outcome:LocalizedReplacementOutcome)->LocalizedReplacementReport {
            .init(outcome,diagnostic:.init(stage:editProgress.stage,reason:editProgress.reason,waits:editProgress.waits,issued:editProgress.issued,fallbackAllowed:outcome == .unavailable))
        }
        func stopped()->LocalizedReplacementReport {report(.stopped(issued:editProgress.issued))}
        func currentElement()->Access.Element? {
            guard process==target.process,identity==target.element,let previous else {editProgress.reason = .targetChanged;return nil}
            let app=access.application(process:target.process)
            guard let element=access.focusedElement(in:app),access.elementsEqual(previous,element),access.capability(of:element) == .editable else {editProgress.reason = .targetChanged;return nil}
            return element
        }
        func authorized() async -> Bool {
            guard !Task.isCancelled else {editProgress.reason = .cancelled;return false}
            guard await authorize(),!Task.isCancelled else {editProgress.reason = .cancelled;return false}
            return true
        }
        func read(_ element:Access.Element)->AccessibleTextState? {
            guard let value=access.textState(of:element) else {editProgress.reason = .textUnavailable;return nil}
            return value
        }
        func wait() async -> Bool {
            editProgress.waits += 1
            do {try await waitForEdit();return true} catch {editProgress.reason = .cancelled;return false}
        }
        func confirmSelection(from previous:AccessibleTextState,to expected:AccessibleTextState) async -> Bool {
            for attempt in 0..<6 {
                guard await authorized(),let element=currentElement(),let actual=read(element) else {return false}
                if actual.matches(expected) {return true}
                guard actual.value.utf16.elementsEqual(expected.value.utf16) else {editProgress.reason = .textMismatch;return false}
                guard actual.selection==previous.selection || actual.selection==expected.selection,
                      actual.selectedText.utf16.elementsEqual(previous.selectedText.utf16) || actual.selectedText.utf16.elementsEqual(expected.selectedText.utf16) else {editProgress.reason = .selectionMismatch;return false}
                guard attempt<5 else {editProgress.reason = .timeout;return false}
                guard await wait() else {return false}
            }
            return false
        }
        guard await authorized(),let element=currentElement() else {return stopped()}
        guard access.canSelectText(in:element) else {editProgress.reason = .unsupported;return report(.unavailable)}
        guard var state=read(element) else {return report(.unavailable)}
        var candidate=LocalizedTextPlan(change:change,state:state)
        // 直前の文字発行の反映だけを有限回待つ。
        for _ in 0..<5 where candidate==nil {
            guard state.selection.length==0,state.selectedText.isEmpty else {editProgress.reason = .selectionMismatch;return stopped()}
            guard await wait(),await authorized(),let element=currentElement(),let fresh=read(element) else {return stopped()}
            state=fresh;candidate=LocalizedTextPlan(change:change,state:state)
        }
        guard let plan=candidate else {editProgress.reason = .textMismatch;return stopped()}
        guard await authorized(),let element=currentElement(),let actual=read(element) else {return stopped()}
        guard actual.matches(plan.original) else {editProgress.reason = .textMismatch;return stopped()}
        // 選択を一度でも変更した後は、Backspace経路へ戻さない。
        editProgress.stage = .selection
        guard !Task.isCancelled else {editProgress.reason = .cancelled;return stopped()}
        guard access.select(plan.selected.selection,in:element) else {editProgress.reason = .selectionFailed;return stopped()}
        editProgress.stage = .selectionReadback
        guard await confirmSelection(from:plan.original,to:plan.selected) else {return stopped()}
        editProgress.stage = .publication
        guard await emit() else {editProgress.reason = .publicationFailed;return stopped()}
        editProgress.issued=true;editProgress.stage = .replacementReadback
        for attempt in 0..<6 {
            guard await authorized(),let element=currentElement(),let actual=read(element) else {return stopped()}
            if actual.matches(plan.replaced) {
                editProgress.stage = .restoration
                guard await authorized(),let element=currentElement(),let fresh=read(element) else {return stopped()}
                guard fresh.matches(plan.replaced) else {editProgress.reason = .textMismatch;return stopped()}
                guard !Task.isCancelled else {editProgress.reason = .cancelled;return stopped()}
                guard access.select(plan.restored.selection,in:element) else {editProgress.reason = .selectionFailed;return stopped()}
                editProgress.stage = .restorationReadback
                guard await confirmSelection(from:plan.replaced,to:plan.restored) else {return stopped()}
                editProgress.stage = .finished;return report(.applied)
            }
            guard actual.matches(plan.selected) else {editProgress.reason = .textMismatch;return stopped()}
            guard attempt<5 else {editProgress.reason = .timeout;return stopped()}
            guard await wait() else {return stopped()}
        }
        editProgress.reason = .timeout;return stopped()
    }
}
@MainActor public final class AXFocusService: FocusService,LocalizedTextReplacing {
    public var onChange: ((FocusSnapshot)->Void)?
    private var generation=FocusGeneration()
    private let probe: any FocusProbe
    private let process: ()->Int32
    private let clock: any SessionClock
    private var polling:Task<Void,Never>?
    private var reading:Task<FocusSnapshot,Never>?
    private var observers:[NSObjectProtocol]=[]
    public init(clock:any SessionClock=MonotonicSessionClock(),diagnostics:DiagnosticRecorder?=nil) {
        probe=NativeFocusProbe(access:NativeFocusAccessibilityAccess(),reportRecovery:{await diagnostics?.submit($0)})
        process={NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0};self.clock=clock
    }
    init(probe:any FocusProbe,process:@escaping ()->Int32,clock:any SessionClock) {self.probe=probe;self.process=process;self.clock=clock}
    public func prepare() async -> FocusSnapshot {
        observeChanges()
        return await read(preparing:true)
    }
    public func read() async -> FocusSnapshot {await read(preparing:false)}
    private func read(preparing:Bool) async -> FocusSnapshot {
        if let reading {
            let snapshot=await reading.value
            guard snapshot.epoch==generation.epoch else {return .init(target:.init(id:nil,capability:.unavailable),epoch:generation.epoch)}
            return snapshot
        }
        let request=generation.begin(),pid=process(),before=generation.epoch
        let task=Task { [self] in
            let target:FocusTarget
            if preparing {
                target=await probe.prepare(process:pid,isCurrent:{ [weak self] in
                    await MainActor.run {
                        guard let self else {return false}
                        return self.generation.request==request && self.process()==pid
                    }
                })
            } else {target=await probe.read(process:pid)}
            guard !Task.isCancelled,pid==process(),generation.accept(target,request:request) else {
                let changed=generation.request != request || pid != process()
                return FocusSnapshot(target:.init(id:nil,capability:.unavailable),epoch:generation.epoch,
                                     invalidation:changed ? .changed:nil)
            }
            let snapshot=FocusSnapshot(target:target,epoch:generation.epoch)
            if before != snapshot.epoch {onChange?(snapshot)}
            return snapshot
        }
        reading=task
        let snapshot=await withTaskCancellationHandler(operation:{await task.value},onCancel:{task.cancel()})
        reading=nil
        guard snapshot.epoch==generation.epoch else {return .init(target:.init(id:nil,capability:.unavailable),epoch:generation.epoch)}
        return snapshot
    }
    public func invalidate() {
        reading?.cancel();generation.invalidate()
        onChange?(.init(target:.init(id:nil,capability:.unavailable),epoch:generation.epoch,invalidation:.changed))
    }
    func replace(_ change:LocalizedTextReplacement,context:InjectionContext,permit:@escaping @MainActor ()->Bool,
                 emit:@escaping @MainActor () -> Bool) async -> LocalizedReplacementOutcome {
        await replaceReporting(change,context:context,permit:permit,emit:emit).outcome
    }
    func replaceReporting(_ change:LocalizedTextReplacement,context:InjectionContext,permit:@escaping @MainActor ()->Bool,
                          emit:@escaping @MainActor () -> Bool) async -> LocalizedReplacementReport {
        let snapshot=await read()
        guard permit(),!Task.isCancelled else {return .init(.stopped(issued:false))}
        guard snapshot.epoch==context.epoch,snapshot.target.id==context.target,snapshot.target.permitsInput else {
            return .init(.stopped(issued:false),diagnostic:.init(stage:.validation,reason:.targetChanged))
        }
        let authorized:@MainActor @Sendable ()->Bool = { [weak self] in
            guard let self else {return false}
            return permit() && !Task.isCancelled && self.generation.epoch==context.epoch && self.generation.target?.id==context.target && self.process()==context.target.process
        }
        return await probe.replaceReporting(change,target:context.target,authorize:{await authorized()},emit:{
            // actorから戻った後も許可・前面PIDと発行を同じMainActor処理単位で確認する。
            await MainActor.run {authorized() && emit()}
        })
    }
    public func start() {
        guard polling==nil else {return}
        observeChanges()
        polling=Task { [self] in
            while !Task.isCancelled {
                _=await read()
                do {try await clock.sleep(for:.milliseconds(100))} catch {break}
            }
        }
    }
    private func observeChanges() {
        guard observers.isEmpty else {return}
        let center=NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification,NSWorkspace.activeSpaceDidChangeNotification] {
            observers.append(center.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated {self?.invalidate()}
            })
        }
    }
    public func stop() async {
        for observer in observers {NSWorkspace.shared.notificationCenter.removeObserver(observer)}
        observers=[];let task=polling;task?.cancel();reading?.cancel();await task?.value;await reading?.value;polling=nil;reading=nil;invalidate()
    }
}
