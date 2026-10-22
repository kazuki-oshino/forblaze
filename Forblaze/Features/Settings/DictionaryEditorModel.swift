import Foundation
import Observation
import ForblazeCore
import ForblazeApplication

@MainActor @Observable final class DictionaryEditorModel {
    var text=""
    var newSource="" {didSet {additionError=nil}}
    var newReplacement="" {didSet {additionError=nil}}
    var addRecognitionHint=false {didSet {additionError=nil}}
    private(set) var additionError:String?
    private var source:String {newSource.trimmingCharacters(in:.whitespacesAndNewlines)}
    private var replacement:String {newReplacement.trimmingCharacters(in:.whitespacesAndNewlines)}
    var canAdd:Bool {canEdit && (!source.isEmpty || addRecognitionHint) && !replacement.isEmpty}
    func addRule() -> Bool {
        guard canAdd else {return false}
        guard newSource.rangeOfCharacter(from:.newlines)==nil,
              newReplacement.rangeOfCharacter(from:.newlines)==nil else {
            additionError="追加する表記には改行を含めないでください。";return false
        }
        guard !source.hasPrefix("#") else {
            additionError="左側の表記の先頭に # は使用できません。";return false
        }
        if addRecognitionHint,RecognitionVocabulary.normalized(replacement)==nil {
            additionError=Self.reason(for:.invalidRecognitionHint);return false
        }
        var lines:[String]=[]
        if !source.isEmpty {lines.append(source+" => "+replacement)}
        if addRecognitionHint {lines.append(RecognitionVocabulary.directive+" "+replacement)}
        let addition=lines.joined(separator:"\n")
        let snapshot=DictionarySnapshot(samples:"",personal:addition)
        if let issue=snapshot.issues.first {
            additionError=Self.reason(for:issue.kind);return false
        }
        guard snapshot.rules.count == (source.isEmpty ? 0:1) else {return false}
        let next=text+(text.isEmpty || text.hasSuffix("\n") ? "":"\n")+addition+"\n"
        if addRecognitionHint,DictionarySnapshot(samples:"",personal:next).issueCount>DictionarySnapshot(samples:"",personal:text).issueCount {
            additionError="認識用語は100件以内にしてください。";return false
        }
        text=next
        clearAddition()
        errorMessage=nil
        return true
    }
    private(set) var savedSnapshot:DictionarySnapshot?
    var savedRules:[DictionaryRule] {savedSnapshot?.rules ?? []}
    private(set) var isBusy=false
    private(set) var errorMessage:String?
    private let store:any DictionaryEditingStore
    private var original:String?
    var canEdit:Bool {!isBusy && original != nil}
    var canSave:Bool {canEdit && text != original}
    init(store:any DictionaryEditingStore) {self.store=store}

    func load() async {
        guard !isBusy else {return}
        isBusy=true;errorMessage=nil;original=nil;savedSnapshot=nil;text="";clearAddition()
        defer {isBusy=false}
        do {
            let loaded=try await store.readText()
            try Task.checkCancellation()
            original=loaded;text=loaded
            savedSnapshot=DictionarySnapshot(samples:"",personal:loaded)
            errorMessage=Self.validationMessage(loaded)
        } catch is CancellationError {
            errorMessage="読み込みを中止しました。もう一度読み込んでください。"
        } catch {
            errorMessage=Self.message(for:error,reading:true)
        }
    }

    func save() async -> Bool {
        guard canSave,let original else {return false}
        guard source.isEmpty && replacement.isEmpty else {
            additionError="入力中の表記があります。「追加」を押して辞書へ反映してください。"
            return false
        }
        let draft=text
        errorMessage=Self.validationMessage(draft)
        guard errorMessage==nil else {return false}
        isBusy=true
        defer {isBusy=false}
        do {
            try await store.saveText(draft,replacing:original)
            self.original=draft
            savedSnapshot=DictionarySnapshot(samples:"",personal:draft)
            return true
        } catch {
            errorMessage=Self.message(for:error,reading:false)
            return false
        }
    }

    func cancel() {
        guard !isBusy else {return}
        text=original ?? "";errorMessage=nil;clearAddition()
    }

    private func clearAddition() {newSource="";newReplacement="";addRecognitionHint=false;additionError=nil}

    private static func reason(for kind:DictionaryIssueKind) -> String {
        switch kind {
        case .syntax:return "「誤認識表記 => 正しい表記」の形式で入力してください。区切りの => は表記に含められません。"
        case .emptySource:return "左側に誤認識される表記を入力してください。"
        case .selfExpansion:return "右側に左側と同じ表記を含めることはできません。"
        case .tooLarge:return "文字数または規則数が上限を超えています。"
        case .invalidRecognitionHint:return "認識用語は文字を含む64文字以内の短い語句にしてください。記号だけの表記や改行は使えません。"
        }
    }

    private static func validationMessage(_ text:String) -> String? {
        let snapshot=DictionarySnapshot(samples:"",personal:text)
        guard snapshot.issueCount>0 else {return nil}
        var lines=snapshot.issues.prefix(6).map {issue in
            "\(issue.line)行目："+reason(for:issue.kind)
        }
        if snapshot.issueCount>6 {lines.append("ほか\(snapshot.issueCount-6)件の不正な規則があります。")}
        return lines.joined(separator:"\n")
    }

    private static func message(for error:any Error,reading:Bool) -> String {
        switch error as? DictionaryFailure {
        case .tooLarge:return "辞書は1 MiB以内にしてください。既存の内容は変更していません。"
        case .changed:return "辞書が別の操作で変更されました。入力内容をコピーしてから、取消で閉じて開き直してください。"
        default:return reading
            ? "辞書を読み込めませんでした。ファイルのアクセス権とUTF-8形式を確認して、再試行してください。"
            : "辞書を保存できませんでした。入力内容は残っています。アクセス権を確認して再試行してください。"
        }
    }
}
