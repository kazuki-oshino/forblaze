import SwiftUI
import ForblazeApplication
import ForblazeCore

@MainActor struct SettingsVoicePage:View {
    @Bindable var model:SettingsViewModel
    var body:some View {
        SettingsGroup(title:"集音") {
            SettingsCard {
                SettingsToggleRow(title:"離れた場所からの声を拾う",detail:"Macから少し離れて話すときの音声認識を優先します。",identifier:"farField",isOn:$model.farField)
                    .disabled(!model.canEditOptions)
            }
        }
        SettingsGroup(title:"文章の補正") {
            SettingsCard {
                SettingsToggleRow(title:"句読点を補正する",detail:"「、」「。」を前後の言葉に合わせて整えます。",identifier:"punctuationCorrection",isOn:$model.punctuationCorrection)
                    .disabled(!model.canEditOptions)
                Divider().padding(.horizontal,18)
                VStack(alignment:.leading,spacing:10) {
                    Label("Jevによる句読点の判定",systemImage:"network")
                        .font(.system(size:12,weight:.semibold))
                    Text("有効にすると、句読点の前後の文章をJevに送信します。送信した文章・判定結果・使用トークン数は、このMacに保存されます。")
                        .font(.system(size:12)).foregroundStyle(.secondary).lineSpacing(4)
                    Text("既存の句読点を置換・削除します。新しい位置への追加や、文章全体の書き換えは行いません。")
                        .font(.system(size:12)).foregroundStyle(.secondary).lineSpacing(4)
                }.padding(18)
            }
            if model.punctuationCorrection && !model.punctuationAvailable {
                SettingsNote(text:"APIキーを読み込めません。.envにTYPESAFE_API_KEYを設定して、アプリを再起動してください。それまでは補正せず入力します。",symbol:"exclamationmark.triangle",warning:true)
            }
        }
        SettingsGroup(title:"クリップボード") {
            SettingsCard {
                SettingsToggleRow(title:"音声入力の終了時にコピーする",detail:"その回に音声入力した全文をクリップボードにコピーします。何も入力されなかった場合は変更しません。",identifier:"copyToClipboard",isOn:$model.copyToClipboard)
                    .disabled(!model.canEditOptions)
            }
        }
        SettingsGroup(title:"反応の調整") {
            SettingsCard {
                SettingsToggleRow(title:"開始前に認識の準備をする",detail:"録音せずに準備します。開始時の待ちを減らせる場合がありますが、待機中のメモリー使用量が増えます。",identifier:"prewarmRecognition",isOn:$model.prewarmRecognition)
                Divider().padding(.horizontal,18)
                SettingsToggleRow(title:"訂正をまとめて反映する",detail:"最初の文字はすぐに入力し、揺れる訂正だけを短く待ちます。遅れて届く句読点補正は見送ります。",identifier:"balancedInput",isOn:$model.balancedInput)
                Divider().padding(.horizontal,18)
                VStack(alignment:.leading,spacing:8) {
                    Picker("音声の受け取り間隔",selection:$model.speechBufferSize) {
                        Text("標準").tag(SpeechBufferSize.standard)
                        Text("短め").tag(SpeechBufferSize.medium)
                        Text("短い").tag(SpeechBufferSize.small)
                        Text("最短").tag(SpeechBufferSize.smallest)
                    }.accessibilityIdentifier("speechBufferSize")
                    Text("短くしても反応が変わらない場合があります。負荷や途切れが増えた場合は標準に戻してください。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(18)
            }.disabled(!model.canEditOptions)
        }
        SettingsNote(text:"変更は自動で保存され、次の音声入力から使われます。",symbol:"checkmark.circle")
    }
}

@MainActor struct SettingsAppearancePage:View {
    @Bindable var model:SettingsViewModel
    var body:some View {
        SettingsCard {
            SettingsBlazePreview(enabled:model.forblazeMode).padding(24)
            Divider().padding(.horizontal,18)
            SettingsToggleRow(title:"フォルブレイズモード",detail:"録音中、画面の四辺に炎が灯ります。",identifier:"forblazeMode",isOn:$model.forblazeMode)
                .disabled(!model.canEditOptions)
        }
        SettingsNote(text:"変更は次の音声入力から反映されます。「視差効果を減らす」が有効な場合、炎の動きは抑えられます。",symbol:"sparkles")
    }
}

/// 動きを使わずに、画面の縁と入力領域の関係を伝える模式図。
private struct SettingsBlazePreview:View {
    let enabled:Bool
    private let ember=Color(red:1,green:0.38,blue:0.14)
    var body:some View {
        VStack(spacing:18) {
            ZStack {
                RoundedRectangle(cornerRadius:14).fill(Color(white:0.08))
                if enabled {
                    RoundedRectangle(cornerRadius:14)
                        .stroke(ember.opacity(0.65),lineWidth:14).blur(radius:15)
                    RoundedRectangle(cornerRadius:14)
                        .stroke(LinearGradient(colors:[.orange,ember,.orange.opacity(0.4),ember],startPoint:.topLeading,endPoint:.bottomTrailing),lineWidth:2)
                    flameEdges
                }
                VStack(spacing:18) {
                    HStack(spacing:5) {
                        ForEach(0..<3) {_ in Circle().fill(.white.opacity(0.17)).frame(width:5,height:5)}
                        Spacer()
                    }
                    Spacer(minLength:0)
                    HStack(spacing:3) {
                        ForEach(Array([8.0,14,22,12,28,18,10,24,32,16,10,20,12].enumerated()),id:\.offset) {_,height in
                            Capsule().fill(enabled ? ember:.white.opacity(0.55)).frame(width:3,height:height)
                        }
                    }
                    Text("声に、灯りを。").font(.system(size:18,weight:.medium)).foregroundStyle(.white.opacity(0.9))
                    HStack(spacing:6) {
                        Circle().fill(enabled ? ember:.white.opacity(0.45)).frame(width:5,height:5)
                        Text("録音中").font(.system(size:10)).foregroundStyle(.white.opacity(0.55))
                    }
                    Spacer(minLength:0)
                }.padding(18)
            }
            .frame(height:225).clipShape(RoundedRectangle(cornerRadius:14))
            .overlay {RoundedRectangle(cornerRadius:14).strokeBorder(.white.opacity(0.12))}
            HStack {
                Text("フォルブレイズモード").font(.system(size:12,weight:.medium))
                Spacer()
                Text(enabled ? "オンのイメージ":"オフのイメージ").font(.system(size:11)).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children:.ignore)
        .accessibilityLabel(enabled ? "プレビュー：画面の四辺に炎が灯り、中央の入力領域は見やすく保たれます":"プレビュー：炎の演出はオフです")
    }
    private var flameEdges:some View {
        GeometryReader {geometry in
            Canvas {context,size in
                for index in 0..<32 {
                    let x=CGFloat(index)/31*size.width
                    let height=CGFloat([16,28,19,42,23,34,18,31][index%8])
                    var flame=Path()
                    flame.move(to:CGPoint(x:x-7,y:size.height))
                    flame.addQuadCurve(to:CGPoint(x:x+3,y:size.height-height),control:CGPoint(x:x-9,y:size.height-height*0.45))
                    flame.addQuadCurve(to:CGPoint(x:x+9,y:size.height),control:CGPoint(x:x-1,y:size.height-height*0.3))
                    context.fill(flame,with:.linearGradient(Gradient(colors:[ember.opacity(0.8),ember.opacity(0)]),startPoint:CGPoint(x:x,y:size.height),endPoint:CGPoint(x:x,y:size.height-height)))
                }
            }.frame(width:geometry.size.width,height:geometry.size.height)
        }.accessibilityHidden(true)
    }
}

@MainActor struct SettingsDictionaryPage:View {
    let model:SettingsViewModel
    let dictionary:DictionaryEditorModel
    let open:()->Void
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            HStack(spacing:10) {
                Text("登録済みの表記").font(.system(size:13,weight:.semibold))
                    .accessibilityAddTraits(.isHeader)
                if dictionary.savedSnapshot != nil {
                    Text("\(dictionary.savedRules.count)件")
                        .font(.system(size:11,weight:.medium)).monospacedDigit().foregroundStyle(.secondary)
                        .padding(.horizontal,8).padding(.vertical,4)
                        .background(.primary.opacity(0.05),in:Capsule())
                }
                Spacer()
                Button {Task {await dictionary.load()}} label:{Image(systemName:"arrow.clockwise")}
                    .buttonStyle(SettingsActionStyle()).disabled(dictionary.isBusy)
                    .help("一覧を再読み込み").accessibilityLabel("一覧を再読み込み")
                    .accessibilityIdentifier("reloadDictionaryList")
                Button(action:open) {Label("辞書を編集…",systemImage:"square.and.pencil")}
                    .buttonStyle(SettingsActionStyle(prominent:true))
                    .disabled(!model.editingReady || !model.sessionIdle || model.capturing || dictionary.isBusy)
                    .accessibilityIdentifier("openDictionary")
            }
            if dictionary.isBusy || (dictionary.savedSnapshot==nil && dictionary.errorMessage==nil) {
                SettingsCard {
                    ProgressView("辞書を読み込んでいます…")
                        .font(.system(size:12)).frame(maxWidth:.infinity).padding(32)
                }
            } else if dictionary.savedSnapshot==nil {
                SettingsNote(text:dictionary.errorMessage ?? "辞書を読み込めませんでした。一覧を再読み込みしてください。",symbol:"exclamationmark.triangle",warning:true)
            } else {
                if let snapshot=dictionary.savedSnapshot,snapshot.issueCount>0 {
                    SettingsNote(text:"読み込めない規則が\(snapshot.issueCount)件あります。編集画面で内容を確認してください。有効な規則は下の一覧で確認できます。",symbol:"exclamationmark.triangle",warning:true)
                }
                if dictionary.savedRules.isEmpty && hints.isEmpty {emptyState}
                if !dictionary.savedRules.isEmpty {rules}
                if !hints.isEmpty {
                    SettingsCard {
                        VStack(alignment:.leading,spacing:10) {
                            Text("認識しやすくする用語（\(hints.count)件）").font(.system(size:13,weight:.semibold))
                            Text(hints.joined(separator:"、")).font(.system(size:13)).textSelection(.enabled)
                                .fixedSize(horizontal:false,vertical:true)
                        }.frame(maxWidth:.infinity,alignment:.leading).padding(18)
                    }.accessibilityIdentifier("savedRecognitionHints")
                }
                Text("保存済みの有効な規則と用語を表示しています。変更は次の音声入力から反映されます。")
                    .font(.system(size:11)).foregroundStyle(.secondary).lineSpacing(3)
            }
        }.task {await dictionary.load()}
    }
    private var hints:[String] {dictionary.savedSnapshot?.recognitionVocabulary.terms ?? []}
    private var rules:some View {
        SettingsCard {
            HStack(spacing:16) {
                Text("誤認識される表記").frame(maxWidth:.infinity,alignment:.leading)
                Color.clear.frame(width:16,height:1).accessibilityHidden(true)
                Text("入力したい表記").frame(maxWidth:.infinity,alignment:.leading)
            }
            .font(.system(size:11,weight:.medium)).foregroundStyle(.secondary).padding(18)
            Divider().padding(.horizontal,18)
            LazyVStack(spacing:0) {
                ForEach(dictionary.savedRules,id:\.source) {rule in
                    HStack(alignment:.top,spacing:16) {
                        Text(rule.source).frame(maxWidth:.infinity,alignment:.leading)
                            .fixedSize(horizontal:false,vertical:true)
                        Image(systemName:"arrow.right").font(.system(size:11))
                            .foregroundStyle(.tertiary).frame(width:16).padding(.top,3).accessibilityHidden(true)
                        Text(rule.replacement.isEmpty ? "（削除）":rule.replacement)
                            .foregroundStyle(rule.replacement.isEmpty ? Color.secondary:Color.primary)
                            .frame(maxWidth:.infinity,alignment:.leading).fixedSize(horizontal:false,vertical:true)
                    }
                    .font(.system(size:13)).textSelection(.enabled).padding(18)
                    .accessibilityElement(children:.combine)
                    if rule.source != dictionary.savedRules.last?.source {Divider().padding(.horizontal,18)}
                }
            }
        }.accessibilityIdentifier("savedDictionaryList")
    }
    private var emptyState:some View {
        SettingsCard {
            VStack(spacing:12) {
                Image(systemName:"text.book.closed").font(.system(size:26,weight:.light))
                    .foregroundStyle(.secondary).accessibilityHidden(true)
                Text(dictionary.savedSnapshot?.issueCount == 0 ? "辞書はまだ空です":"有効な表記がありません")
                    .font(.system(size:15,weight:.semibold))
                Text("「辞書を編集…」から、使いたい表記を登録できます。")
                    .font(.system(size:12)).foregroundStyle(.secondary)
            }.frame(maxWidth:.infinity).padding(.vertical,42).padding(.horizontal,18)
        }
    }
}

@MainActor struct SettingsPermissionsPage:View {
    let model:SettingsViewModel
    @State private var showsDiagnostics=false
    var body:some View {
        SettingsNote(text:model.availability.canStart ? "音声入力を使う準備ができています。":"音声入力を使うには、以下の状態を確認してください。",symbol:model.availability.canStart ? "checkmark.shield":"lock.shield",warning:!model.availability.canStart)
        HStack {
            Text("権限を変更したら、状態を再確認してください。")
                .font(.system(size:11)).foregroundStyle(.secondary)
            Spacer()
            Button {model.onRefresh?()} label:{Label("状態を再確認",systemImage:"arrow.clockwise")}
                .buttonStyle(SettingsActionStyle()).accessibilityIdentifier("refreshPermissions")
        }
        SettingsGroup(title:"アクセス権") {
            SettingsCard {
                ForEach(PermissionKind.allCases,id:\.self) {kind in
                    SettingsRow(title:title(kind),detail:detail(kind)) {
                        HStack(spacing:12) {
                            statusLabel(status(kind),ready:model.availability.permissions[kind] == .granted)
                            Button("確認") {model.onPermission?(kind)}
                                .buttonStyle(SettingsActionStyle()).accessibilityLabel(title(kind)+"を確認")
                        }
                    }
                    if kind != PermissionKind.allCases.last {Divider().padding(.horizontal,18)}
                }
            }
        }
        SettingsGroup(title:"認識とキー監視") {
            SettingsCard {
                SettingsRow(title:"日本語の音声認識モデル",detail:"") {
                    statusLabel(modelStatus,ready:model.availability.model == .installed)
                }
                Divider().padding(.horizontal,18)
                SettingsRow(title:"開始・終了キーの監視",detail:"") {
                    statusLabel(model.availability.eventTap == .available ? "利用可能":model.availability.eventTap == .failed ? "確認が必要":"未確認",ready:model.availability.eventTap == .available)
                }
            }

        }
        DisclosureGroup("診断情報",isExpanded:$showsDiagnostics) {
            VStack(alignment:.leading,spacing:12) {
                Text("認識本文を含まない、最新64件の情報です。設定画面を開いた時点の状態を表示します。")
                    .foregroundStyle(.secondary)
                if model.observationSummary.isEmpty && model.metadataSummary.isEmpty {
                    Text("診断情報はまだありません。").foregroundStyle(.secondary)
                }
                if !model.observationSummary.isEmpty {Text("認識API観測\n"+model.observationSummary).textSelection(.enabled)}
                if !model.metadataSummary.isEmpty {Text("認識区間\n"+model.metadataSummary).textSelection(.enabled)}
            }.font(.system(size:11,design:.monospaced)).frame(maxWidth:.infinity,alignment:.leading).padding(.top,12)
        }.font(.system(size:12)).padding(.horizontal,2)
    }
    private func statusLabel(_ title:String,ready:Bool) -> some View {
        Label(title,systemImage:ready ? "checkmark.circle.fill":"minus.circle")
            .font(.system(size:11,weight:.medium))
            .foregroundStyle(ready ? Color.secondary:Color.primary)
            .fixedSize()
    }
    private func title(_ kind:PermissionKind) -> String {
        switch kind {
        case .inputMonitoring:"入力監視"
        case .accessibility:"アクセシビリティ"
        case .microphone:"マイク"
        case .speech:"音声認識"
        }
    }
    private func detail(_ kind:PermissionKind) -> String {
        switch kind {
        case .inputMonitoring:"開始・終了キーを受け取ります。"
        case .accessibility:"選択した入力欄に文字を入力します。"
        case .microphone:"あなたの声を受け取ります。"
        case .speech:"声を日本語の文字に変換します。"
        }
    }
    private func status(_ kind:PermissionKind) -> String {
        switch model.availability.permissions[kind] ?? .unknown {
        case .granted:"許可済み"
        case .denied:"未許可"
        case .restricted:"制限あり"
        case .unknown:"未確認"
        }
    }
    private var modelStatus:String {
        switch model.availability.model {
        case .installed:"準備完了"
        case .downloading:"ダウンロード中"
        case .missing:"初回入力時に取得"
        case .unsupported:"このMacでは未対応"
        case .unknown:"未確認"
        }
    }
}
