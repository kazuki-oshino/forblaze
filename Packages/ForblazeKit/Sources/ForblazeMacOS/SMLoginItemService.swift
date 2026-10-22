import ServiceManagement
import ForblazeApplication
@MainActor public final class SMLoginItemService:LoginItemService {
    private let app=SMAppService.mainApp
    public init() {}
    public var status:LoginItemStatus {
        switch app.status {
        case .enabled:return .enabled
        case .notRegistered:return .disabled
        case .requiresApproval:return .approvalRequired
        case .notFound:return .unavailable
        @unknown default:return .unavailable
        }
    }
    public func setEnabled(_ enabled:Bool) async throws {
        do {
            if enabled {if status != .enabled {try app.register()}}
            else if status != .disabled {try await app.unregister()}
        } catch {throw LoginItemFailure.registration}
    }
}
