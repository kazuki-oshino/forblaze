import Foundation
public struct SessionID: Hashable, Sendable {
    public let value: UUID
    public init(_ value: UUID = UUID()) { self.value = value }
}
public struct TargetEpoch: Equatable, Sendable {
    public let value: UInt64
    public init(_ value: UInt64) { self.value = value }
}
public enum SessionPhase: Equatable, Sendable { case idle, preparing, listening, finishing, stopping }
public enum InputPermission: Equatable, Sendable { case closed, open, suspended }
public enum SessionFailure: Error, Equatable, Sendable {
    case preparation, recognition, cleanup, finalizationTimeout, permissionLost, audioDevice, interrupted, injection
    case target(TargetIssue)
}
public enum SessionEvent: Sendable {
    case toggle(SessionID)
    case prepared(SessionID, TargetEpoch)
    case injectionFailed(SessionID)
    case manualInput
    case targetChanged(TargetEpoch, issue: TargetIssue = .changed)
    case failed(SessionID, SessionFailure)
    case finalized(SessionID)
    case timeout(SessionID)
    case cleaned(SessionID)
    case interrupt(SessionFailure)
}
public enum SessionEffect: Equatable, Sendable {
    case prepare(SessionID), finish(SessionID), cancel(SessionID)
}
public struct SessionState: Equatable, Sendable {
    public private(set) var phase: SessionPhase = .idle
    public private(set) var permission: InputPermission = .closed
    public private(set) var session: SessionID?
    public private(set) var epoch = TargetEpoch(0)
    public private(set) var lastError: SessionFailure?
    public private(set) var failurePhase: SessionPhase?
    public init() {}
    public func allows(_ id: SessionID, _ epoch: TargetEpoch) -> Bool {
        session == id && self.epoch == epoch && permission == .open && (phase == .listening || phase == .finishing)
    }
    public mutating func handle(_ event: SessionEvent) -> [SessionEffect] {
        func stop(_ state: inout Self, error: SessionFailure? = nil) -> [SessionEffect] {
            guard state.phase != .idle else {return []}
            if let error { state.lastError = error; state.failurePhase = state.phase }
            guard state.phase != .stopping, let id = state.session else { return [] }
            state.phase = .stopping; state.permission = .closed
            return [.cancel(id)]
        }
        switch event {
        case .toggle(let id):
            switch phase {
            case .idle:
                session = id; lastError = nil; failurePhase = nil; phase = .preparing; permission = .closed
                return [.prepare(id)]
            case .preparing, .finishing: return stop(&self)
            case .listening:
                if permission == .suspended { return stop(&self) }
                phase = .finishing
                return session.map { [.finish($0)] } ?? []
            case .stopping: return []
            }
        case .prepared(let id, let epoch):
            guard session == id, phase == .preparing else { return [] }
            self.epoch = epoch; phase = .listening; permission = .open
        case .injectionFailed(let id):
            guard session==id else {return []}
            if phase == .finishing {return stop(&self,error:.injection)}
            if phase == .listening {permission = .suspended;lastError = .injection;failurePhase = phase}
        case .manualInput:
            return stop(&self)
        case .targetChanged(let epoch, let issue):
            guard phase != .idle,phase != .stopping,epoch != self.epoch else { return [] }
            self.epoch = epoch
            return stop(&self, error: .target(issue))
        case .failed(let id, let error):
            guard session == id,phase != .stopping || error == .cleanup else { return [] }
            return stop(&self, error: error)
        case .timeout(let id):
            guard session == id, phase == .finishing else { return [] }
            return stop(&self, error: .finalizationTimeout)
        case .finalized(let id):
            guard session == id, phase == .finishing else { return [] }
            return stop(&self)
        case .cleaned(let id):
            guard session == id, phase == .stopping else { return [] }
            phase = .idle; permission = .closed; session = nil
        case .interrupt(let error): return stop(&self, error: error)
        }
        return []
    }
}
