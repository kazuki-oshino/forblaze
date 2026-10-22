/// 比較可能な入力方針。認識の確定と、後処理による編集の終了を分ける。
public enum InputPresentationPolicy:Sendable {
    case direct,balanced
    public var punctuationLifetime:Duration {self == .balanced ? .milliseconds(1500):.seconds(8)}
    public var settlesPunctuation:Bool {self == .balanced}
    public func deadline(lastIssue:Duration,firstPending:Duration,lastChange:Duration,correction:Bool)->Duration {
        let interval=lastIssue+(correction ? .milliseconds(150):.milliseconds(75))
        guard self == .balanced,correction else {return interval}
        // キューと安定待ちを加算せず、一つの期限で扱う。
        return min(max(interval,lastChange + .milliseconds(120)),firstPending + .milliseconds(300))
    }
}
