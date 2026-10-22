/// テストが任意の順番で非同期操作を完了させる。実時間を待たない。
public actor ControlledGate<Value: Sendable> {
    private var waiters: [CheckedContinuation<Value, Never>] = []
    private var pending: [Value] = []
    public init() {}
    public func next() async -> Value {
        if !pending.isEmpty { return pending.removeFirst() }
        return await withCheckedContinuation { waiters.append($0) }
    }
    public func send(_ value: Value) {
        if !waiters.isEmpty { waiters.removeFirst().resume(returning: value) }
        else { pending.append(value) }
    }
}
