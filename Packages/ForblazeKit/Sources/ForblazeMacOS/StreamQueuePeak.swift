import Synchronization
/// 生音声tapからも参照する固定サイズの数値。フレームや本文を保持しない。
final class StreamQueuePeak: Sendable {
    private let capacity:Int
    private let maximum=Mutex(0)
    init(capacity:Int) {self.capacity=max(0,capacity)}
    var value:Int {maximum.withLock {$0}}
    func observe(remainingCapacity:Int) {
        let count=capacity-min(capacity,max(0,remainingCapacity))
        maximum.withLock {$0=max($0,count)}
    }
    func reset() {maximum.withLock {$0=0}}
}
