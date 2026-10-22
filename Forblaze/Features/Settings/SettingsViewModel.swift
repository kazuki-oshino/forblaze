import Observation
import ForblazeCore
import ForblazeApplication
@MainActor @Observable final class SettingsViewModel {
    private(set) var editingReady=false
    private(set) var sessionIdle=true
    private(set) var current:TriggerBinding?
    private(set) var candidate:TriggerBinding?
    private(set) var capturing=false
    private(set) var released=false
    private(set) var error:SettingsFailure?
    private(set) var preferences:AppSettings?
    var farField:Bool {
        get {preferences?.farField ?? true}
        set {setOption(.farField,enabled:newValue)}
    }
    var sounds:Bool {
        get {preferences?.sounds ?? true}
        set {setOption(.sounds,enabled:newValue)}
    }
    var muteOutputDuringDictation:Bool {
        get {preferences?.muteOutputDuringDictation ?? false}
        set {setOption(.muteOutputDuringDictation,enabled:newValue)}
    }
    var forblazeMode:Bool {
        get {preferences?.forblazeMode ?? false}
        set {setOption(.forblazeMode,enabled:newValue)}
    }
    var punctuationCorrection:Bool {
        get {preferences?.punctuationCorrection ?? false}
        set {setOption(.punctuationCorrection,enabled:newValue)}
    }
    var copyToClipboard:Bool {
        get {preferences?.copyToClipboard ?? false}
        set {setOption(.copyToClipboard,enabled:newValue)}
    }
    var prewarmRecognition:Bool {
        get {preferences?.prewarmRecognition ?? false}
        set {setOption(.prewarmRecognition,enabled:newValue)}
    }
    var balancedInput:Bool {
        get {preferences?.balancedInput ?? false}
        set {setOption(.balancedInput,enabled:newValue)}
    }
    var speechBufferSize:SpeechBufferSize {
        get {preferences?.speechBufferSize ?? .standard}
        set {settings.setBufferSize(newValue,isIdle:editingReady && session.state.phase == .idle);update()}
    }
    var canEditOptions:Bool {editingReady && sessionIdle && current != nil && error != .restore}
    private func setOption(_ option:SettingsOption,enabled:Bool) {
        settings.setOption(option,enabled:enabled,isIdle:editingReady && session.state.phase == .idle)
        update()
    }
    var punctuationAvailable=true
    var availability=Availability()
    private(set) var metadataSummary=""
    private(set) var observationSummary=""
    private let observations:()->[SpeechObservation]
    var onPermission:((PermissionKind)->Void)?
    var onRefresh:(()->Void)?
    var onLoginChanged:((Bool)->Void)?
    private(set) var launchAtLogin=false
    private(set) var loginMessage:String?
    func updateLogin(status:LoginItemStatus,error:LoginItemFailure?) {
        launchAtLogin=status == .enabled
        if error != nil {loginMessage="ログイン時起動の設定を変更できませんでした"}
        else if status == .approvalRequired {loginMessage="システム設定でログイン時起動の承認が必要です"}
        else if status == .unavailable {loginMessage="ログイン時起動の状態をOSから確認できません。設定変更後に結果を確認してください"}
        else {loginMessage=nil}
    }
    func requestLogin(_ enabled:Bool) {guard editingReady && session.state.phase == .idle else {return};onLoginChanged?(enabled)}
    private let issues:()->[DictionaryIssue]
    private(set) var dictionaryWarning:String?
    static func warning(_ issues:[DictionaryIssue]) -> String? {
        guard !issues.isEmpty else {return nil}
        let lines=issues.prefix(20).map {String($0.line)}.joined(separator:"、")
        return "個人辞書の"+lines+(issues.count>20 ? "ほか":"")+"行目に不正な規則があります。有効な行は使用します。"
    }
    private let session:SessionCoordinator
    private let settings:SettingsCoordinator
    init(session:SessionCoordinator,settings:SettingsCoordinator,issues:@escaping ()->[DictionaryIssue]={[]},observations:@escaping ()->[SpeechObservation]={[]}) {
        self.issues=issues;self.observations=observations
        self.session=session;self.settings=settings
        settings.onChange={ [weak self] in self?.update() }
        update()
    }
    func synchronize() {update()}
    private func update() {
        sessionIdle=session.state.phase == .idle
        dictionaryWarning=Self.warning(issues())
        preferences=settings.current
        current=settings.current?.binding;candidate=settings.candidate;capturing=settings.capturing
        released=settings.keysReleased;error=settings.error
    }
    func open() async {
        editingReady=false
        await session.finishAndWait()
        editingReady=session.state.phase == .idle
        observationSummary=observations().map { observation in
            let range=observation.range.map {"\($0.start)〜\($0.end)秒 "} ?? ""
            let final=observation.isFinal.map {$0 ? "確定 " : "途中 "} ?? ""
            let code=observation.errorCode.map {" code=\($0)"} ?? ""
            return range+final+observation.kind.rawValue+code
        }.joined(separator:"\n")
        metadataSummary=session.recognitionMetadata.map { "\($0.range.start)〜\($0.range.end)秒 \($0.isFinal ? "確定" : "途中")" }.joined(separator:"\n")
        update()
    }
    func beginCapture() {settings.beginCapture(isIdle:editingReady && session.state.phase == .idle)}
    func cancel() {settings.cancel();update()}
    func useDefault() {settings.useDefault(isIdle:editingReady && session.state.phase == .idle)}
    func save() {
        settings.save(isIdle:editingReady && session.state.phase == .idle,farField:farField,sounds:sounds,punctuationCorrection:punctuationCorrection,forblazeMode:forblazeMode)
        update()
    }
    var canSave:Bool {editingReady && session.state.phase == .idle && capturing && candidate != nil && released}

}

@MainActor extension SettingsViewModel {
    static func keyName(_ binding:TriggerBinding?) -> String {
        guard let binding else {return "キー設定が必要"}
        let functions:[UInt16]=[122,120,99,118,96,97,98,100,101,109,103,111,105,107,113,106,64,79,80,90]
        if let index=functions.firstIndex(of:binding.keyCode) {return "F"+String(index+1)}
        return [UInt16(53):"Escape",71:"Clear",114:"Insert",115:"Home",116:"Page Up",119:"End",121:"Page Down"][binding.keyCode] ?? "キーコード \(binding.keyCode)"
    }
    var errorText:String? {
        guard let error else {return nil}
        switch error {
        case .sessionActive:return "収録の終了を待ってください"
        case .invalidCandidate:return "単独の非文字キーを選んでください。Enter、Space、文字、修飾キーは選べません"
        case .keyHeld:return "キーを離してから確定してください"
        case .apply:return "キーを適用できませんでした"
        case .save:return "保存できませんでした。以前の設定へ戻しました"
        case .restore:return "設定を復元できません。キー操作を無効にしました"
        case .corrupt:return "保存したキーが破損または未対応です。キーを選び直してください"
        }
    }
}
