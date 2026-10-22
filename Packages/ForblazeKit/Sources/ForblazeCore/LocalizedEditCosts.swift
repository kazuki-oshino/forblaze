/// 同じ入力先・収録で成功した処理だけを比較する。許可・本文照合は別途必須。
public struct LocalizedEditCosts:Sendable {
    private var ordinary:[Double]=[]
    private var localized:[Double]=[]
    public init() {}
    public mutating func recordOrdinary(milliseconds:Double,strokes:Int) {
        guard strokes>0,milliseconds.isFinite,milliseconds>0 else {return}
        ordinary.append(milliseconds/Double(strokes))
        if ordinary.count>8 {ordinary.removeFirst()}
    }
    public mutating func recordLocalized(milliseconds:Double) {
        guard milliseconds.isFinite,milliseconds>0 else {return}
        localized.append(milliseconds)
        if localized.count>8 {localized.removeFirst()}
    }
    public var hasEvidence:Bool {!ordinary.isEmpty && !localized.isEmpty}
    public func shouldAttempt(_ change:LocalizedTextReplacement)->Bool {
        guard change.requiresCostEvidence else {return true}
        guard hasEvidence,let strokes=change.ordinaryStrokes else {return false}
        let normal=ordinary.reduce(0,+)/Double(ordinary.count)*Double(strokes)
        // 最近の最も遅い範囲操作に余裕を持たせる。平均だけで有利と判定しない。
        return (localized.max() ?? .infinity)*1.25<normal
    }
}

extension LocalizedTextReplacement {
    public var requiresCostEvidence:Bool {expectedTail.count<32 || preservedSuffix.count<16}
    public var ordinaryStrokes:Int? {
        var units=0,chunks=0
        for character in replacement+preservedSuffix {
            let count=String(character).utf16.count
            guard count<=16 else {return nil}
            if units+count>16 {chunks += 1;units=0}
            units += count
        }
        return expectedTail.count+chunks+(units>0 ? 1:0)
    }
}
