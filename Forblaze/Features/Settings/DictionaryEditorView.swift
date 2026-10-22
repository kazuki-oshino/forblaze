import SwiftUI

@MainActor struct DictionaryEditorView:View {
    @Bindable var model:DictionaryEditorModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    private enum Field:Hashable {case source,replacement,editor}
    @FocusState private var focusedField:Field?

    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            HStack(spacing:12) {
                Image(systemName:"text.book.closed").font(.system(size:22)).foregroundStyle(SettingsStyle.accent)
                    .accessibilityHidden(true)
                Text("個人辞書").font(.system(size:23,weight:.bold))
            }
            VStack(alignment:.leading,spacing:6) {
                Text("音声認識で間違いやすい表記と、入力したい表記を1行ずつ登録します。")
                Text("空行と # で始まるコメントも使えます。保存した内容は次の収録から反映されます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment:.leading,spacing:8) {
                HStack(alignment:.bottom,spacing:12) {
                    VStack(alignment:.leading,spacing:6) {
                        Text("誤認識される表記").font(.caption)
                        TextField("例：クロードコード",text:$model.newSource)
                            .focused($focusedField,equals:.source)
                            .onSubmit {focusedField = .replacement}
                            .accessibilityLabel("誤認識される表記")
                            .accessibilityIdentifier("dictionarySource")
                    }.frame(maxWidth:.infinity)
                    Image(systemName:"arrow.right").padding(.bottom,6).accessibilityHidden(true)
                    VStack(alignment:.leading,spacing:6) {
                        Text("入力したい表記").font(.caption)
                        TextField("例：Claude Code",text:$model.newReplacement)
                            .focused($focusedField,equals:.replacement)
                            .onSubmit {addRule()}
                            .accessibilityLabel("入力したい表記")
                            .accessibilityIdentifier("dictionaryReplacement")
                    }.frame(maxWidth:.infinity)
                    Button("追加",action:addRule)
                        .buttonStyle(SettingsActionStyle())
                        .disabled(!model.canAdd)
                        .accessibilityIdentifier("addDictionaryRule")
                }
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .disabled(!model.canEdit)
                Toggle("入力したい表記を、認識しやすくする用語としても使う",isOn:$model.addRecognitionHint)
                    .font(.callout)
                    .disabled(!model.canEdit)
                    .accessibilityIdentifier("dictionaryRecognitionHint")
                if model.addRecognitionHint {
                    Text("人名・製品名など短い語句を登録できます。誤認識表記を空にすると、認識用語だけを追加します。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let message=model.additionError {
                    Text(message).font(.callout).foregroundStyle(.red)
                }
                Text("「追加」で下の辞書に反映し、「保存して閉じる」で保存します。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("登録する表記").font(.system(size:12,weight:.semibold)).foregroundStyle(.secondary)
            TextEditor(text:$model.text)
                .font(.body.monospaced())
                .autocorrectionDisabled()
                .focused($focusedField,equals:.editor)
                .disabled(!model.canEdit)
                .scrollContentBackground(.hidden)
                .padding(12)
                .background(.background,in:RoundedRectangle(cornerRadius:12))
                .overlay {RoundedRectangle(cornerRadius:12).strokeBorder(.primary.opacity(0.12))}
                .accessibilityLabel("辞書の規則")
                .accessibilityHint("1行に、誤認識される表記、半角のイコールと大なり記号、入力したい表記を入力します")
                .accessibilityIdentifier("dictionaryEditor")
            if let message=model.errorMessage {
                ScrollView {
                    Text(message).foregroundStyle(.red).font(.callout)
                        .frame(maxWidth:.infinity,alignment:.leading).textSelection(.enabled)
                }.frame(maxHeight:92)
            }
            HStack {
                if model.isBusy {ProgressView().controlSize(.small)}
                if !model.canEdit && !model.isBusy {
                    Button("読み込みを再試行") {Task {await model.load()}}
                }
                Spacer()
                Button("キャンセル") {model.cancel();dismiss()}
                    .keyboardShortcut(.cancelAction).buttonStyle(SettingsActionStyle()).disabled(model.isBusy)
                Button("保存して閉じる") {
                    Task {if await model.save() {dismiss()}}
                }
                .keyboardShortcut("s",modifiers:.command)
                .buttonStyle(SettingsActionStyle(prominent:true))
                .disabled(!model.canSave)
                .accessibilityIdentifier("saveDictionary")
            }
        }
        .padding(28)
        .frame(width:620,height:680)
        .background(SettingsStyle.canvas(scheme))
        .tint(SettingsStyle.accent)
        .interactiveDismissDisabled()
        .task {await model.load();focusedField=model.canEdit ? .source:nil}
    }

    private func addRule() {if model.addRule() {focusedField = .source}}
}
