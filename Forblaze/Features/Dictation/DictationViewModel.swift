import Observation
import ForblazeCore
import ForblazeApplication
@MainActor @Observable final class DictationViewModel {
    private(set) var state=SessionState()
    var preview:String {""}
    var level:Float=0
    var forblazeMode=false
    var modelProgress:Double?
    var availability=Availability()
    private let toggleCommand: () -> Void
    init(toggle:@escaping () -> Void) {toggleCommand=toggle}
    func update(state:SessionState,preview _:String) {self.state=state;if state.phase != .preparing {modelProgress=nil};if state.phase == .idle {level=0}}
    func toggle() {toggleCommand()}
    var hasRecordingAppearance:Bool {state.phase == .listening && state.permission == .open}
    var panelTitle:String {hasRecordingAppearance ? "録音中" : title}
    var recoveryHelp:String? {targetNotice?.help}
    var panelHeight:Double {
        if suspensionHelp != nil {return 188}
        if recoveryHelp != nil {return 188}
        if errorText != nil {return 132}
        if modelProgress != nil {return 120}
        return 84
    }
    var suspensionHelp:String? {
        guard state.phase == .listening,state.permission == .suspended else {return nil}
        return "収録は続いています。\n開始キーを1回押して終了してください。\n入力位置を選び直し、もう1回押すと音声入力を再開できます。"
    }
    var title:String {
        switch state.phase {
        case .idle: return "待機中"
        case .preparing: return "準備中"
        case .listening: return state.permission == .suspended ? "文字入力保留中" : "認識中"
        case .finishing: return "入力確定中"
        case .stopping: return "終了処理中"
        }
    }
    var errorText:String? {
        guard let error=state.lastError else {return nil}
        switch error {
        case .finalizationTimeout:return "最後の認識結果を確定できませんでした"
        case .target:
            return targetNotice?.message
        case .permissionLost:return "権限またはキー監視を確認してください"
        case .audioDevice:return "マイクの接続または音声形式を確認してください"
        case .preparation:return "モデルまたはマイクの準備に失敗しました"
        case .recognition:return "音声認識が終了しました"
        case .cleanup:return "終了処理が完了していません"
        case .interrupted:return "中断しました。キー操作で再開できます"
        case .injection:return "文字入力に失敗しました。入力位置を確認してください"
        }
    }
    private var targetNotice:(message:String,help:String)? {
        // 後始末が済むまで再試行を促さず、失敗時点の状態で案内を選ぶ。
        guard state.phase == .idle,case .target(let issue)=state.lastError else {return nil}
        switch (state.failurePhase == .preparing,issue) {
        case (true,.unavailable):
            return ("入力欄を確認できません","入力したい欄をクリックして、開始キーを押してください")
        case (true,.noneditable):
            return ("この場所には音声入力できません","文字を入力できる欄を選んでください")
        case (true,.protected):
            return ("保護された入力欄には音声入力できません","別の入力欄を選んでください")
        case (true,.changed):
            return ("入力先が変わったため、開始を取り消しました","入力したい欄で、開始キーを押してください")
        case (false,.changed):
            return ("入力先が変わったため、音声入力を終了しました","続ける場合は、入力先を選んで開始キーを押してください")
        case (false,.unavailable):
            return ("入力先を確認できなくなったため、音声入力を終了しました","入力欄を選び直して、開始キーを押してください")
        case (false,.noneditable):
            return ("入力先が編集できないため、音声入力を終了しました","文字を入力できる欄を選んで、開始キーを押してください")
        case (false,.protected):
            return ("保護された入力欄のため、音声入力を終了しました","別の入力欄を選んで、開始キーを押してください")
        }
    }
}
