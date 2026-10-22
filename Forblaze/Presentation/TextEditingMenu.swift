import AppKit

/// メニューバー常駐アプリでも、設定の入力欄で標準の編集キーを使えるようにする。
@MainActor enum TextEditingMenu {
    static func installIfNeeded() {
        guard NSApplication.shared.mainMenu==nil else {return}
        let menu=NSMenu()
        let appItem=NSMenuItem()
        let appMenu=NSMenu(title:"forblaze")
        appMenu.addItem(withTitle:"forblazeを終了",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        appItem.submenu=appMenu;menu.addItem(appItem)
        let editItem=NSMenuItem()
        let editMenu=NSMenu(title:"編集")
        editMenu.addItem(withTitle:"取り消す",action:Selector(("undo:")),keyEquivalent:"z")
        let redo=editMenu.addItem(withTitle:"やり直す",action:Selector(("redo:")),keyEquivalent:"z")
        redo.keyEquivalentModifierMask=[.command,.shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle:"カット",action:#selector(NSText.cut(_:)),keyEquivalent:"x")
        editMenu.addItem(withTitle:"コピー",action:#selector(NSText.copy(_:)),keyEquivalent:"c")
        editMenu.addItem(withTitle:"ペースト",action:#selector(NSText.paste(_:)),keyEquivalent:"v")
        editMenu.addItem(withTitle:"すべて選択",action:#selector(NSText.selectAll(_:)),keyEquivalent:"a")
        editItem.submenu=editMenu;menu.addItem(editItem)
        NSApplication.shared.mainMenu=menu
    }
}
