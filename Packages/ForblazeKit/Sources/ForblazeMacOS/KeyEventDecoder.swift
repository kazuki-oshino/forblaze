import CoreGraphics
/// functionフラグはFキー自身にも付く。物理Fnの押下とは区別する。
enum KeyEventDecoder {
    static func modifiers(flags: CGEventFlags, fnPressed: Bool) -> UInt64 {
        var normalized=flags.intersection([.maskShift,.maskControl,.maskAlternate,.maskCommand])
        if fnPressed {normalized.insert(.maskSecondaryFn)}
        return normalized.rawValue
    }
}
