import ForblazeCore
public enum SystemInterruption:Sendable {case locked,sleep,audioChanged,permissionsLost,tapDisabled,quit,resumed}
@MainActor public final class InterruptionCoordinator {
    private let session:SessionCoordinator
    private let trigger:any TriggerService
    public var onResume:(()->Void)?
    public init(session:SessionCoordinator,trigger:any TriggerService) {self.session=session;self.trigger=trigger}
    public func handle(_ event:SystemInterruption) {
        if case .resumed=event {trigger.resetKeys();onResume?();return}
        let reason:SessionFailure
        switch event {
        case .audioChanged:reason = .audioDevice
        case .permissionsLost,.tapDisabled:reason = .permissionLost
        default:reason = .interrupted
        }
        if session.state.phase != .idle {session.send(.interrupt(reason))}
        trigger.setEnabled(false);trigger.resetKeys()
        if case .tapDisabled=event {onResume?()}
    }
}
public enum LoginItemStatus:Sendable {case disabled,enabled,approvalRequired,unavailable}
public enum LoginItemFailure:Error,Sendable {case registration}
@MainActor public protocol LoginItemService:AnyObject {
    var status:LoginItemStatus {get}
    func setEnabled(_ enabled:Bool) async throws
}
@MainActor public final class LoginItemCoordinator {
    private let service:any LoginItemService
    public private(set) var status:LoginItemStatus
    public private(set) var error:LoginItemFailure?
    public var onChange:(()->Void)?
    public init(service:any LoginItemService) {self.service=service;status=service.status}
    private var task:Task<Void,Never>?
    public func setEnabled(_ enabled:Bool) {
        let previous=task;previous?.cancel()
        task=Task { [self] in
            await previous?.value
            guard !Task.isCancelled else {return}
            do {try await service.setEnabled(enabled);error=nil}
            catch {self.error = .registration}
            status=service.status;onChange?()
        }
    }
    public func awaitIdle() async {await task?.value}
    public func shutdown() async {task?.cancel();await task?.value;task=nil}
}
