import AppKit
import SwiftUI
import ForblazeApplication

enum SettingsPage:String,CaseIterable,Identifiable {
    case general,voice,appearance,dictionary,permissions
    var id:String {rawValue}
    var title:String {
        switch self {
        case .general:"一般"
        case .voice:"音声入力"
        case .appearance:"演出"
        case .dictionary:"個人辞書"
        case .permissions:"アクセス権"
        }
    }
    var symbol:String {
        switch self {
        case .general:"slider.horizontal.3"
        case .voice:"waveform"
        case .appearance:"flame"
        case .dictionary:"text.book.closed"
        case .permissions:"lock.shield"
        }
    }
    var subtitle:String {
        switch self {
        case .general:"起動と操作を、いつもの使い方に。"
        case .voice:"声の拾い方と、入力する文章を調整します。"
        case .appearance:"録音中のひとときに、forblazeらしさを。"
        case .dictionary:"名前や専門用語を、あなたの表記で。"
        case .permissions:"音声入力に必要なMacのアクセス権を管理します。"
        }
    }
}

@MainActor struct SettingsView:View {
    @Bindable var model:SettingsViewModel
    let dictionary:DictionaryEditorModel
    @Environment(\.colorScheme) private var scheme
    @State private var page:SettingsPage? = .general
    @State private var sheet:SettingsSheet?
    private enum SettingsSheet:String,Identifiable {
        case key,dictionary
        var id:String {rawValue}
    }
    init(model:SettingsViewModel,dictionary:DictionaryEditorModel,initialPage:SettingsPage = .general) {
        self.model=model;self.dictionary=dictionary;_page=State(initialValue:initialPage)
    }
    private var selectedPage:SettingsPage {page ?? .general}
    var body:some View {
        HStack(spacing:0) {
            sidebar.frame(width:196)
            Rectangle().fill(.primary.opacity(0.07)).frame(width:1)
            VStack(alignment:.leading,spacing:0) {
                header
                ScrollView {
                    VStack(alignment:.leading,spacing:24) {
                        if let error=model.errorText {
                            SettingsNote(text:error,symbol:"exclamationmark.triangle",warning:true)
                        }
                        if !model.editingReady {
                            SettingsNote(text:"音声入力の終了を待っています。",symbol:"hourglass")
                        }
                        content
                    }.padding(.horizontal,32).padding(.bottom,32)
                        .frame(maxWidth:760,alignment:.leading).frame(maxWidth:.infinity)
                }.id(selectedPage).scrollBounceBehavior(.basedOnSize)
            }
            .frame(maxWidth:.infinity,maxHeight:.infinity)
            .background(SettingsStyle.canvas(scheme))
        }
        .tint(SettingsStyle.accent).accentColor(SettingsStyle.accent)
        .frame(minWidth:820,minHeight:620)
        .sheet(item:$sheet,onDismiss:{if model.capturing {model.cancel()}}) {item in
            switch item {
            case .key:SettingsKeyEditor(model:model)
            case .dictionary:DictionaryEditorView(model:dictionary)
            }
        }
    }
    private var sidebar:some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(spacing:8) {
                Image(nsImage:NSImage(named:"AppIcon") ?? NSApplication.shared.applicationIconImage)
                    .resizable().scaledToFit().frame(width:44,height:44)
                    .accessibilityHidden(true)
                Text("forblaze").font(.system(size:20,weight:.semibold,design:.rounded)).tracking(-0.5)
            }.padding(.horizontal,22).padding(.top,28).padding(.bottom,32)
            Text("設定").font(.system(size:11,weight:.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal,26).padding(.bottom,8)
            List(SettingsPage.allCases,selection:$page) {item in
                Label(item.title,systemImage:item.symbol)
                    .font(.system(size:13,weight:page == item ? .semibold:.regular))
                    .labelStyle(.titleAndIcon).padding(.vertical,8)
                    .tag(item).accessibilityIdentifier("settingsPage_"+item.rawValue)
            }
            .listStyle(.sidebar).scrollContentBackground(.hidden)
            .padding(.horizontal,8)
            Spacer(minLength:20)
            VStack(alignment:.leading,spacing:8) {
                Label("自動保存",systemImage:"checkmark.circle")
                    .font(.system(size:12,weight:.medium))
                Text("スイッチの変更は\nそのまま反映されます。")
                    .font(.system(size:11)).lineSpacing(4).foregroundStyle(.secondary)
            }.padding(24)
        }
        .background(scheme == .dark ? Color(white:0.14):Color(red:0.932,green:0.926,blue:0.912))
    }
    private var header:some View {
        VStack(alignment:.leading,spacing:9) {
            Text(selectedPage.title).font(.system(size:28,weight:.bold)).tracking(-0.7)
                .accessibilityAddTraits(.isHeader)
            Text(selectedPage.subtitle).font(.system(size:12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth:696,alignment:.leading).frame(maxWidth:.infinity,alignment:.center)
        .padding(.horizontal,32).padding(.top,32).padding(.bottom,26)
    }
    @ViewBuilder private var content:some View {
        switch selectedPage {
        case .general:general
        case .voice:SettingsVoicePage(model:model)
        case .appearance:SettingsAppearancePage(model:model)
        case .dictionary:SettingsDictionaryPage(model:model,dictionary:dictionary) {sheet = .dictionary}
        case .permissions:SettingsPermissionsPage(model:model)
        }
    }
    private var general:some View {
        VStack(alignment:.leading,spacing:24) {
            SettingsGroup(title:"ショートカット") {
                SettingsCard {
                    HStack(alignment:.center,spacing:22) {
                        SettingsKeycap(name:SettingsViewModel.keyName(model.current))
                        VStack(alignment:.leading,spacing:6) {
                            Text("ひとつのキーで、話し始める。")
                                .font(.system(size:16,weight:.semibold))
                            Text("同じキーをもう一度押すと、音声入力が終了します。")
                                .font(.system(size:12)).foregroundStyle(.secondary)
                                .fixedSize(horizontal:false,vertical:true).lineSpacing(3)
                        }
                        Spacer(minLength:0)
                    }.padding(22)
                    Divider().padding(.horizontal,18)
                    SettingsRow(title:"開始・終了キー",detail:"単独のファンクションキーなどを使えます。") {
                        Button("キーを変更…") {model.beginCapture();if model.capturing {sheet = .key}}
                            .buttonStyle(SettingsActionStyle()).disabled(!model.editingReady || !model.sessionIdle)
                            .accessibilityIdentifier("changeTriggerKey")
                    }
                }
            }
            SettingsGroup(title:"起動とサウンド") {
                SettingsCard {
                    SettingsToggleRow(title:"ログイン時に起動",detail:"Macにログインすると、メニューバーに常駐します。",identifier:"launchAtLogin",isOn:Binding(get:{model.launchAtLogin},set:{model.requestLogin($0)}))
                        .disabled(!model.editingReady || !model.sessionIdle)
                    Divider().padding(.horizontal,18)
                    SettingsToggleRow(title:"開始・終了音",detail:"音声入力の開始と終了を、短い音でお知らせします。",identifier:"recordingSounds",isOn:$model.sounds)
                        .disabled(!model.canEditOptions)
                    Divider().padding(.horizontal,18)
                    SettingsToggleRow(title:"音声入力中はMacの音を消す",detail:"開始音が鳴り終わると音量を0にし、終了時に元の音量へ戻します。",identifier:"muteOutputDuringDictation",isOn:$model.muteOutputDuringDictation)
                        .disabled(!model.canEditOptions)
                }
                if let message=model.loginMessage {SettingsNote(text:message,warning:true)}
            }
            SettingsNote(text:"入力欄を選んでから、開始キーを押してください。手入力・Enter・カーソル移動・クリックでも音声入力は終了します。Enterは入力先の通常の操作として通ります。",symbol:"cursorarrow.click")
        }
    }
}

@MainActor struct SettingsKeyEditor:View {
    @Bindable var model:SettingsViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    var body:some View {
        VStack(alignment:.leading,spacing:24) {
            VStack(alignment:.leading,spacing:8) {
                Text("開始・終了キー").font(.system(size:23,weight:.bold))
                Text("使いたいキーをひとつ押して、離してください。")
                    .font(.system(size:13)).foregroundStyle(.secondary)
            }
            VStack(spacing:18) {
                SettingsKeycap(name:model.candidate.map {SettingsViewModel.keyName($0)} ?? "…",large:true)
                Text(model.candidate == nil ? "キーを待っています":model.released ? "このキーで開始・終了します":"キーを離してください")
                    .font(.system(size:13,weight:.medium))
            }.frame(maxWidth:.infinity).padding(.vertical,20)
            if let error=model.errorText {SettingsNote(text:error,symbol:"exclamationmark.triangle",warning:true)}
            else {SettingsNote(text:"文字・Enter・Space・修飾キーは使えません。キーの取得中に音声入力が始まることはありません。")}
            HStack {
                Button("F8に戻す") {model.useDefault()}.buttonStyle(SettingsActionStyle())
                if model.candidate != nil {Button("取り直す") {model.beginCapture()}.buttonStyle(SettingsActionStyle())}
                Spacer()
                Button("キャンセル") {model.cancel();dismiss()}.buttonStyle(SettingsActionStyle())
                Button("このキーを使う") {model.save();if !model.capturing {dismiss()}}
                    .buttonStyle(SettingsActionStyle(prominent:true)).disabled(!model.canSave)
                    .keyboardShortcut(.defaultAction).accessibilityIdentifier("confirmTriggerKey")
            }
        }.padding(28).frame(width:560).background(SettingsStyle.canvas(scheme)).interactiveDismissDisabled()
    }
}
