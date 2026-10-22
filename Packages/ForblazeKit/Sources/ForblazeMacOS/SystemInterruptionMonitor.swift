import AppKit
import AVFoundation
import ForblazeApplication
@MainActor public final class SystemInterruptionMonitor {
    public var onEvent:((SystemInterruption)->Void)?
    public var onAvailability:((Availability)->Void)?
    private let permissions:any PermissionService
    private let clock:any SessionClock
    private var observers:[(NotificationCenter,NSObjectProtocol)]=[]
    private var polling:Task<Void,Never>?
    public init(permissions:any PermissionService,clock:any SessionClock=MonotonicSessionClock()) {self.permissions=permissions;self.clock=clock}
    public func start() {
        guard polling==nil else {return}
        func observe(_ center:NotificationCenter,_ name:Notification.Name,_ event:SystemInterruption) {
            let token=center.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated {self?.onEvent?(event)}
            }
            observers.append((center,token))
        }
        let workspace=NSWorkspace.shared.notificationCenter
        observe(workspace,NSWorkspace.willSleepNotification,.sleep)
        observe(workspace,NSWorkspace.didWakeNotification,.resumed)
        observe(workspace,NSWorkspace.sessionDidResignActiveNotification,.locked)
        observe(workspace,NSWorkspace.sessionDidBecomeActiveNotification,.resumed)
        observe(NotificationCenter.default,.AVAudioEngineConfigurationChange,.audioChanged)
        observe(DistributedNotificationCenter.default(),Notification.Name("com.apple.screenIsLocked"),.locked)
        observe(DistributedNotificationCenter.default(),Notification.Name("com.apple.screenIsUnlocked"),.resumed)
        polling=Task { [self] in
            var previous:Bool?
            while !Task.isCancelled {
                let availability=await permissions.snapshot()
                guard !Task.isCancelled else {break}
                onAvailability?(availability)
                if !availability.canStart {onEvent?(.permissionsLost)}
                else if previous==false {onEvent?(.resumed)}
                previous=availability.canStart
                do {try await clock.sleep(for:.seconds(2))} catch {break}
            }
        }
    }
    public func stop() async {
        for (center,token) in observers {center.removeObserver(token)}
        observers=[];polling?.cancel();await polling?.value;polling=nil
    }
}
