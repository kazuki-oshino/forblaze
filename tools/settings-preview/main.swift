import AppKit
import SwiftUI
import ForblazeCore
import ForblazeApplication

@MainActor private final class PreviewTrigger:TriggerService {
    var keysReleased=true
    var onToggle:((BindingRevision)->Void)?
    var onKeyInput:((KeyInput)->Void)?
    func start() throws {}
    func stop() {}
    func setEnabled(_ enabled:Bool) {}
    func apply(_ binding:TriggerBinding?,revision:BindingRevision) throws {}
    func resetKeys() {}
}
@MainActor private final class PreviewStore:SettingsStore {
    var value:StoredSettings = .valid(.init(forblazeMode:true))
    var failNext=false
    func load() throws -> StoredSettings {value}
    func replace(_ value:StoredSettings) throws {
        if failNext {failNext=false;throw SettingsFailure.save}
        self.value=value
    }
}
@MainActor private final class PreviewSpeech:SpeechService {
    func start(session:SessionID) async throws -> AsyncThrowingStream<RecognitionResult,Error> {throw CancellationError()}
    func closeInput() {}
    func stopAudio() async {}
    func finalize() async throws {}
    func cancel() async throws {}
}
private actor PreviewDictionary:DictionaryEditingStore {
    var text="# よく使う表記\nフォーブレイズ => forblaze\n音声にゅうりょく => 音声入力\nえーぴーあい => API\n"
    var readFailure=false
    func setReadFailure(_ value:Bool) {readFailure=value}
    func readText() async throws -> String {
        if readFailure {throw DictionaryFailure.read}
        return text
    }
    func saveText(_ text:String,replacing original:String) async throws {self.text=text}
}

@MainActor private final class PreviewDelegate:NSObject,NSApplicationDelegate {
    var window:NSWindow?
    var keyMonitor:Any?
    func applicationDidFinishLaunching(_ notification:Notification) {
        Task {await render()}
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool {true}
    func render() async {
        do {
            TextEditingMenu.installIfNeeded()
            let output=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
            let store=PreviewStore(),trigger=PreviewTrigger()
            let coordinator=SettingsCoordinator(trigger:trigger,store:store)
            coordinator.restoreAtStartup()
            let model=SettingsViewModel(session:SessionCoordinator(speech:PreviewSpeech(),clock:MonotonicSessionClock()),settings:coordinator)
            model.availability = .init(permissions:Dictionary(uniqueKeysWithValues:PermissionKind.allCases.map {($0,.granted)}),model:.installed,eventTap:.available)
            model.onLoginChanged={model.updateLogin(status:$0 ? .enabled:.disabled,error:nil)}
            let dictionaryStore=PreviewDictionary()
            let dictionary=DictionaryEditorModel(store:dictionaryStore)
            await model.open()
            let window=NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:700),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
            window.title="forblaze 設定 — プレビュー";window.isReleasedWhenClosed=false
            window.contentMinSize=NSSize(width:820,height:620);self.window=window
            window.center();window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps:true)
            keyMonitor=NSEvent.addLocalMonitorForEvents(matching:[.keyDown,.keyUp]) {event in
                MainActor.assumeIsolated {
                    if coordinator.capturing {
                        trigger.keysReleased=event.type == .keyUp
                        coordinator.receive(.init(event.type == .keyUp ? .up:.down,event.keyCode,modifiers:UInt64(event.modifierFlags.intersection([.shift,.control,.option,.command]).rawValue),isRepeat:event.isARepeat))
                    }
                }
                return event
            }
            if CommandLine.arguments.contains("--live") {
                window.contentView=NSHostingView(rootView:SettingsView(model:model,dictionary:dictionary))
                return
            }
            for scheme in [ColorScheme.light,.dark] {
                for page in SettingsPage.allCases {
                    let root=SettingsView(model:model,dictionary:dictionary,initialPage:page).environment(\.colorScheme,scheme)
                    try await capture(root,name:page.rawValue+(scheme == .dark ? "-dark":"-light"),window:window,output:output)
                }
            }
            for page in [SettingsPage.general,.voice,.permissions] {
                let root=SettingsView(model:model,dictionary:dictionary,initialPage:page).environment(\.colorScheme,.light)
                try await capture(root,name:page.rawValue+"-compact",window:window,output:output,size:NSSize(width:820,height:620))
            }
            for scheme in [ColorScheme.light,.dark] {
                try await capture(SettingsView(model:model,dictionary:dictionary,initialPage:.voice).environment(\.colorScheme,scheme),
                                  name:scheme == .dark ? "voice-bottom-dark":"voice-bottom-light",window:window,output:output,size:NSSize(width:820,height:620),scrollToBottom:true)
            }
            try await capture(SettingsView(model:model,dictionary:dictionary).environment(\.colorScheme,.dark),name:"general-contrast-dark",window:window,output:output)
            model.forblazeMode=false
            try await capture(SettingsView(model:model,dictionary:dictionary,initialPage:.appearance).environment(\.colorScheme,.light),name:"appearance-off",window:window,output:output)
            store.failNext=true;model.sounds=false
            try await capture(SettingsView(model:model,dictionary:dictionary).environment(\.colorScheme,.light),name:"save-failure",window:window,output:output)
            model.sounds=false
            model.punctuationCorrection=true;model.punctuationAvailable=false
            try await capture(SettingsView(model:model,dictionary:dictionary,initialPage:.voice).environment(\.colorScheme,.light),name:"voice-warning",window:window,output:output)
            model.availability = .init(permissions:[.microphone:.denied,.speech:.restricted])
            try await capture(SettingsView(model:model,dictionary:dictionary,initialPage:.permissions).environment(\.colorScheme,.light),name:"permissions-needed",window:window,output:output)
            model.beginCapture();coordinator.receive(.init(.down,36))
            try await capture(SettingsKeyEditor(model:model).environment(\.colorScheme,.light),name:"key-invalid",window:window,output:output,size:NSSize(width:616,height:460))
            coordinator.receive(.init(.down,101));coordinator.receive(.init(.up,101))
            try await capture(SettingsKeyEditor(model:model).environment(\.colorScheme,.dark),name:"key-ready-dark",window:window,output:output,size:NSSize(width:616,height:460))
            model.cancel()
            try await capture(DictionaryEditorView(model:dictionary).environment(\.colorScheme,.light),name:"dictionary-editor",window:window,output:output,size:NSSize(width:620,height:680))
            try await dictionaryStore.saveText("",replacing:"")
            try await capture(SettingsView(model:model,dictionary:dictionary,initialPage:.dictionary).environment(\.colorScheme,.light),name:"dictionary-empty",window:window,output:output)
            try await dictionaryStore.saveText("# forblaze-hint-v1: forblaze\n# forblaze-hint-v1: Claude Code\n",replacing:"")
            try await capture(SettingsView(model:model,dictionary:dictionary,initialPage:.dictionary).environment(\.colorScheme,.light),name:"dictionary-hints-only",window:window,output:output)
            try await dictionaryStore.saveText("長い名前を含んだ音声認識の表記を確認するための例 => 一覧の幅に合わせて折り返しながら全文を確認できる置換後の表記\n区切りなし\n削除する言葉 => ",replacing:"")
            try await capture(SettingsView(model:model,dictionary:dictionary,initialPage:.dictionary).environment(\.colorScheme,.dark),name:"dictionary-long-warning-dark",window:window,output:output,size:NSSize(width:820,height:620))
            await dictionaryStore.setReadFailure(true)
            try await capture(SettingsView(model:model,dictionary:dictionary,initialPage:.dictionary).environment(\.colorScheme,.light),name:"dictionary-read-error",window:window,output:output)
            NSApplication.shared.terminate(nil)
        } catch {fputs("設定プレビュー失敗: \(error)\n",stderr);exit(1)}
    }
    func capture<V:View>(_ root:V,name:String,window:NSWindow,output:URL,size:NSSize=NSSize(width:900,height:700),scrollToBottom:Bool=false) async throws {
        window.setContentSize(size)
        let hosting=NSHostingView(rootView:root)
        window.contentView=hosting
        window.appearance=NSAppearance(named:name.contains("contrast") ? .accessibilityHighContrastDarkAqua:name.contains("dark") ? .darkAqua:.aqua)
        try await Task.sleep(for:.milliseconds(180))
        hosting.layoutSubtreeIfNeeded();hosting.displayIfNeeded()
        if scrollToBottom {
            func scroll(_ view:NSView) {
                if let area=view as? NSScrollView,let document=area.documentView {
                    area.contentView.scroll(to:NSPoint(x:0,y:document.isFlipped ? max(0,document.bounds.height-area.contentView.bounds.height):0))
                    area.reflectScrolledClipView(area.contentView)
                }
                for child in view.subviews {scroll(child)}
            }
            scroll(hosting)
            try await Task.sleep(for:.milliseconds(100))
            hosting.layoutSubtreeIfNeeded();hosting.displayIfNeeded()
        }
        guard let bitmap=hosting.bitmapImageRepForCachingDisplay(in:hosting.bounds) else {throw CocoaError(.fileWriteUnknown)}
        hosting.cacheDisplay(in:hosting.bounds,to:bitmap)
        guard let png=bitmap.representation(using:.png,properties:[:]) else {throw CocoaError(.fileWriteUnknown)}
        try png.write(to:output.appendingPathComponent(name+".png"))
    }
}
@main struct SettingsPreview {
    @MainActor static func main() {
        let app=NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate=PreviewDelegate();app.delegate=delegate
        app.run()
    }
}
