import AppKit
import SwiftUI
@MainActor final class SettingsWindowController:NSObject,NSWindowDelegate {
    private let model:SettingsViewModel
    private let dictionary:DictionaryEditorModel
    private var window:NSWindow?
    init(model:SettingsViewModel,dictionary:DictionaryEditorModel) {self.model=model;self.dictionary=dictionary}
    func show() {
        TextEditingMenu.installIfNeeded()
        if window == nil {
            let window=NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:700),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
            window.title="forblaze 設定";window.isReleasedWhenClosed=false
            window.contentMinSize=NSSize(width:820,height:620)
            window.setFrameAutosaveName("forblaze.settings.v2")
            window.contentView=NSHostingView(rootView:SettingsView(model:model,dictionary:dictionary,initialPage:model.availability.canStart ? .general:.permissions));window.delegate=self
            window.center();self.window=window
        }
        NSApplication.shared.activate(ignoringOtherApps:true);window?.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification:Notification) {model.cancel()}
}
