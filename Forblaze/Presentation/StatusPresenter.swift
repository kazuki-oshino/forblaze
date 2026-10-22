import AppKit
import SwiftUI
import ForblazeCore
import ForblazeApplication
@MainActor final class StatusPresenter:NSObject {
    var onSettings:(()->Void)?
    var onRefresh:(()->Void)?
    var onPermission:((PermissionKind)->Void)?
    var onQuit:(()->Void)?
    private let item=NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
    private let panel:StatusPanelController
    private let blaze:BlazeOverlayController
    private let model:DictationViewModel
    init(model:DictationViewModel,positionStore:any PanelPositionStore) {
        self.model=model
        panel=StatusPanelController(model:model,store:positionStore)
        blaze=BlazeOverlayController(model:model,anchor:panel.panel)
        super.init()
        refresh()
    }
    func refresh() {
        let menu=NSMenu()
        let status=NSMenuItem(title:model.title,action:nil,keyEquivalent:"");status.isEnabled=false;menu.addItem(status)
        menu.addItem(.separator())
        add("設定…",#selector(settings),to:menu)
        add("状態を再確認",#selector(checkStatus),to:menu)
        let permissions=NSMenu()
        for (index,kind) in PermissionKind.allCases.enumerated() {
            let labels=["入力監視","アクセシビリティ","マイク","音声認識"]
            let status=model.availability.permissions[kind] == .granted ? "許可済み" : "許可を確認"
            let entry=NSMenuItem(title:labels[index]+"："+status,action:#selector(permission(_:)),keyEquivalent:"")
            entry.tag=index;entry.target=self;permissions.addItem(entry)
        }
        let entry=NSMenuItem(title:"権限",action:nil,keyEquivalent:"");entry.submenu=permissions;menu.addItem(entry)
        menu.addItem(NSMenuItem(title:"日本語モデル："+model.availability.model.rawValue,action:nil,keyEquivalent:""))
        menu.addItem(.separator());add("終了",#selector(quit),to:menu)
        item.menu=menu
        panel.update(size:NSSize(width:324,height:model.panelHeight+32),visible:model.state.phase != .idle || model.errorText != nil)
        blaze.refresh()
        item.button?.image=StatusBarIcon.image(for:model.state)
        item.button?.toolTip="forblaze："+model.title
        item.button?.setAccessibilityLabel("forblaze："+model.title)
    }
    func containsPanel(at point:CGPoint) -> Bool {panel.containsPointer(at:point)}
    func stopEffects() {blaze.hide()}
    func shutdown() {blaze.shutdown(permanently:true)}
    private func add(_ title:String,_ action:Selector,to menu:NSMenu) {
        let item=NSMenuItem(title:title,action:action,keyEquivalent:"");item.target=self;menu.addItem(item)
    }
    @objc private func settings() {onSettings?()}
    @objc private func checkStatus() {onRefresh?()}
    @objc private func permission(_ item:NSMenuItem) {onPermission?(PermissionKind.allCases[item.tag])}
    @objc private func quit() {onQuit?()}
}
