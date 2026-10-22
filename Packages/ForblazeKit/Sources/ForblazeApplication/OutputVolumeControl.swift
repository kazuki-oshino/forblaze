/// 音声入力中だけ出力音量を下げ、変更前の音量へ戻す。
@MainActor public protocol OutputVolumeControl:AnyObject {
    func silence()
    func restore()
}
