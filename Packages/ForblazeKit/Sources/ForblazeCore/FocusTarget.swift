import Foundation
public struct TargetID: Hashable, Sendable {
    public let process: Int32
    public let element: UInt64
    public init(process: Int32, element: UInt64) { self.process=process;self.element=element }
}
public enum TargetCapability: Sendable {case editable, noneditable, protected, unavailable}
public enum TargetIssue: String, Sendable {case changed, unavailable, noneditable, protected}
public struct FocusTarget: Equatable, Sendable {
    public let id: TargetID?
    public let capability: TargetCapability
    public init(id: TargetID?, capability: TargetCapability) {self.id=id;self.capability=capability}
    public var permitsInput: Bool {capability == .editable && id != nil}
    public var inputIssue: TargetIssue? {
        switch capability {
        case .editable: return id == nil ? .unavailable:nil
        case .noneditable: return .noneditable
        case .protected: return .protected
        case .unavailable: return .unavailable
        }
    }
}
/// 問い合わせ開始後に届く旧応答を拒否する。識別不能も世代変更として扱う。
public struct FocusGeneration: Sendable {
    public private(set) var epoch=TargetEpoch(0)
    public private(set) var target: FocusTarget?
    public private(set) var request: UInt64=0
    public init() {}
    public mutating func begin() -> UInt64 {request += 1;return request}
    @discardableResult public mutating func accept(_ value: FocusTarget, request: UInt64) -> Bool {
        guard request == self.request else {return false}
        if value != target {epoch=TargetEpoch(epoch.value+1);target=value}
        return true
    }
    public mutating func invalidate() {self.request += 1;target=nil;epoch=TargetEpoch(epoch.value+1)}
}
