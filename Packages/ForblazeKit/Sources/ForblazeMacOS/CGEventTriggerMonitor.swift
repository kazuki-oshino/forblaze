import Foundation
import CoreGraphics
import ForblazeCore
import ForblazeApplication
@MainActor public final class CGEventTriggerMonitor: TriggerService {
    public var onToggle: ((BindingRevision) -> Void)?
    public var onKeyInput: ((KeyInput) -> Void)?
    public var onManualInput: (() -> Void)?
    public var onDisabled: (() -> Void)?
    public var preservesRecordingAtPoint: ((CGPoint) -> Bool)?
    public var keysReleased: Bool { pressed.isEmpty }
    private var pressed: Set<UInt16> = []
    private var rule = TriggerRule(binding: nil)
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    public init() {}
    public func setEnabled(_ enabled: Bool) { rule.enabled = enabled }
    public func apply(_ binding: TriggerBinding?, revision: BindingRevision) throws {
        if let binding, !binding.isValid { throw SettingsFailure.invalidCandidate }
        rule.binding = binding; rule.revision = revision
    }
    public func resetKeys() { pressed.removeAll(); rule.reset() }
    public func process(_ input: KeyInput, marker:Int64=0) -> KeyDecision {
        guard marker != InjectionMarker.value else {return .pass}
        if input.kind == .down { pressed.insert(input.code) } else { pressed.remove(input.code) }
        let decision = rule.handle(input)
        onKeyInput?(input)
        if decision == .toggle { onToggle?(rule.revision) }
        if decision == .pass,input.kind == .down {onManualInput?()}
        return decision
    }
    public func processPointer(marker:Int64=0,editing:Bool,location:CGPoint?=nil,isPrimary:Bool=true) -> Bool {
        guard editing,marker != InjectionMarker.value else {return true}
        if isPrimary,let location,preservesRecordingAtPoint?(location)==true {return true}
        onManualInput?()
        return true
    }
    public func disable() { rule.enabled = false; resetKeys(); onDisabled?() }
    public func start() throws {
        guard tap == nil else { return }
        let types:[CGEventType]=[.keyDown,.keyUp,.leftMouseDown,.rightMouseDown,.otherMouseDown,.scrollWheel,.flagsChanged]
        let mask=types.reduce(CGEventMask(0)) {$0 | (1 << $1.rawValue)}
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            // このtapのrun-loop sourceは必ずメインrun loopへ設置する。
            let pass = MainActor.assumeIsolated {
                let monitor = Unmanaged<CGEventTriggerMonitor>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    monitor.disable(); return true
                }
                let marker=event.getIntegerValueField(.eventSourceUserData)
                guard marker != InjectionMarker.value else {return true}
                if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
                    return monitor.processPointer(marker:marker,editing:true,location:event.location,isPrimary:type == .leftMouseDown)
                }
                guard type == .keyDown || type == .keyUp else {return true}
                let flags = KeyEventDecoder.modifiers(flags:event.flags,fnPressed:CGEventSource.keyState(.hidSystemState,key:63))
                let input = KeyInput(type == .keyUp ? .up : .down,
                                     UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
                                     modifiers: flags,
                                     isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                                     revision: monitor.rule.revision)
                return monitor.process(input,marker:marker) == .pass
            }
            return pass ? Unmanaged.passUnretained(event) : nil
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask), callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { throw SessionFailure.permissionLost }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault,tap,0)
        CFRunLoopAddSource(CFRunLoopGetMain(),source,.commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }
    public func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(),source,.commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil; tap = nil; resetKeys()
    }
}
