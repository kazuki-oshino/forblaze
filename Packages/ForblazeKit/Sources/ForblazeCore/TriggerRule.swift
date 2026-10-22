public struct KeyInput: Sendable {
    public enum Kind: Sendable { case down, up }
    public let kind: Kind
    public let code: UInt16
    public let modifiers: UInt64
    public let isRepeat: Bool
    public let revision: BindingRevision
    public init(_ kind: Kind, _ code: UInt16 = 100, modifiers: UInt64 = 0, isRepeat: Bool = false, revision: BindingRevision = .init(1)) {
        self.kind = kind; self.code = code; self.modifiers = modifiers; self.isRepeat = isRepeat; self.revision = revision
    }
}
public enum KeyDecision: Equatable, Sendable { case pass, consume, toggle }
public struct TriggerRule: Sendable {
    public var binding: TriggerBinding?
    public var revision: BindingRevision
    public var enabled = true
    public private(set) var consumed: Set<UInt16> = []
    public init(binding: TriggerBinding? = .defaultBinding, revision: BindingRevision = .init(1)) {
        self.binding = binding; self.revision = revision
    }
    public mutating func reset() { consumed.removeAll() }
    public mutating func handle(_ input: KeyInput) -> KeyDecision {
        if consumed.contains(input.code) {
            if input.kind == .up { consumed.remove(input.code) }
            return .consume
        }
        guard enabled, let binding, binding.isValid, input.revision == revision,
              input.code == binding.keyCode, input.modifiers == 0,
              input.kind == .down, !input.isRepeat else { return .pass }
        consumed.insert(input.code)
        return .toggle
    }
}
