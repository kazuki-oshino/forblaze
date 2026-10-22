public enum PermissionKind: String, CaseIterable, Sendable { case inputMonitoring, accessibility, microphone, speech }
public enum PermissionStatus: String, Sendable { case unknown, denied, granted, restricted }
public enum ModelStatus: String, Sendable { case unknown, unsupported, missing, downloading, installed }
public enum EventTapStatus: String, Sendable { case unknown, available, failed }
public struct Availability: Equatable, Sendable {
    public var permissions: [PermissionKind: PermissionStatus]
    public var model: ModelStatus
    public var eventTap: EventTapStatus
    public init(permissions:[PermissionKind:PermissionStatus]=[:],model:ModelStatus = .unknown,eventTap:EventTapStatus = .unknown) {
        self.permissions=permissions;self.model=model;self.eventTap=eventTap
    }
    public var canStart: Bool { blockers.isEmpty }
    public var blockers: [String] {
        var reasons = PermissionKind.allCases.filter { permissions[$0] != .granted }.map(\.rawValue)
        if model == .unsupported || model == .unknown { reasons.append("model") }
        if eventTap != .available { reasons.append("eventTap") }
        return reasons
    }
}
@MainActor public protocol PermissionService: AnyObject {
    func snapshot() async -> Availability
    func request(_ kind:PermissionKind) async -> Bool
}
