import ForblazeCore
public struct FocusSnapshot: Equatable, Sendable {
    public let target: FocusTarget
    public let epoch: TargetEpoch
    public let invalidation: TargetIssue?
    public var inputIssue: TargetIssue? {invalidation ?? target.inputIssue}
    public init(target: FocusTarget, epoch: TargetEpoch, invalidation: TargetIssue?=nil) {
        self.target=target;self.epoch=epoch;self.invalidation=invalidation
    }
}
@MainActor public protocol FocusService: AnyObject {
    var onChange: ((FocusSnapshot)->Void)? {get set}
    func prepare() async -> FocusSnapshot
    func read() async -> FocusSnapshot
    func start()
    func stop() async
}
extension FocusService {
    public func prepare() async -> FocusSnapshot {await read()}
}
