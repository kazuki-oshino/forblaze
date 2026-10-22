/// 入力先への貼り付けとは独立した、終了時のコピー先。
@MainActor public protocol ClipboardWriter:AnyObject {
    func write(_ text:String)
}
