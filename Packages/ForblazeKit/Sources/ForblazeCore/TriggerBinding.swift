public struct TriggerBinding: Codable, Equatable, Sendable {
    public let version: Int
    public let keyCode: UInt16
    public let modifiers: UInt64
    public init(version: Int = 1, keyCode: UInt16, modifiers: UInt64 = 0) {
        self.version = version; self.keyCode = keyCode; self.modifiers = modifiers
    }
    public static let defaultBinding = TriggerBinding(keyCode: 100)
    public static let allowedKeyCodes: Set<UInt16> = [53, 64, 71, 79, 80, 90, 96, 97, 98, 99, 100, 101, 103, 105, 106, 107, 109, 111, 113, 114, 115, 116, 118, 119, 120, 121, 122]
    public var isValid: Bool { version == 1 && modifiers == 0 && Self.allowedKeyCodes.contains(keyCode) }
}

public struct BindingRevision: Equatable, Sendable {
    public let value: UInt64
    public init(_ value: UInt64) { self.value = value }
}
public enum StoredBinding: Equatable, Sendable {
    case missing, valid(TriggerBinding), invalid
}
