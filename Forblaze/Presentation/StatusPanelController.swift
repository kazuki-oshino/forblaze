import AppKit
import SwiftUI
import ForblazeApplication

enum StatusPanelPlacement {
    static func origin(preferred:PanelPosition?,size:NSSize,screens:[NSRect],defaultScreen:NSRect?) -> NSPoint {
        let fallback=defaultScreen ?? screens.first ?? .zero
        let point: NSPoint
        if let preferred,preferred.isValid {point=NSPoint(x:preferred.x,y:preferred.y)}
        else {point=NSPoint(x:fallback.maxX-size.width-24,y:fallback.minY+16)}
        guard !screens.isEmpty else {return point}
        let frame=NSRect(origin:point,size:size)
        func overlap(_ screen:NSRect) -> CGFloat {
            let intersection=frame.intersection(screen)
            return intersection.isNull ? 0 : intersection.width*intersection.height
        }
        func distance(_ screen:NSRect) -> CGFloat {
            hypot(frame.midX-screen.midX,frame.midY-screen.midY)
        }
        let screen=screens.max {
            let a=overlap($0),b=overlap($1)
            return a==b ? distance($0)>distance($1) : a<b
        }!
        return NSPoint(x:min(max(point.x,screen.minX),max(screen.minX,screen.maxX-size.width)),
                       y:min(max(point.y,screen.minY),max(screen.minY,screen.maxY-size.height)))
    }
    static func appKitPoint(from point:CGPoint,primaryScreen:NSRect) -> NSPoint {
        NSPoint(x:point.x,y:primaryScreen.maxY-point.y)
    }
}

/// 入力先のkey windowを保ったまま、パネル全体をドラッグできる。
@MainActor class RecordingPanel:NSPanel {
    var onDragEnded:(()->Void)?
    private var dragOffset:NSPoint?
    var isDragging:Bool {dragOffset != nil}
    override var canBecomeKey:Bool {false}
    override var canBecomeMain:Bool {false}
    override func sendEvent(_ event:NSEvent) {
        switch event.type {
        case .leftMouseDown:dragOffset=event.locationInWindow
        case .leftMouseDragged:
            guard let dragOffset else {return}
            let point=convertPoint(toScreen:event.locationInWindow)
            setFrameOrigin(NSPoint(x:point.x-dragOffset.x,y:point.y-dragOffset.y))
        case .leftMouseUp:
            dragOffset=nil;onDragEnded?()
        default:super.sendEvent(event)
        }
    }
    func cancelDrag() {dragOffset=nil}
}

@MainActor final class StatusPanelController:NSObject,NSWindowDelegate {
    let panel:RecordingPanel
    private let store:any PanelPositionStore
    private let screens:()->[NSRect]
    private let defaultScreen:()->NSRect?
    private let primaryScreen:()->NSRect?
    private let windowAtPoint:(NSPoint)->Int
    private var preferred:PanelPosition?
    private var size=NSSize(width:324,height:116)
    private var isLayingOut=false
    init(model:DictationViewModel,store:any PanelPositionStore,
         screens:@escaping ()->[NSRect]={NSScreen.screens.map(\.visibleFrame)},
         defaultScreen:@escaping ()->NSRect?={NSScreen.main?.visibleFrame},
         primaryScreen:@escaping ()->NSRect?={NSScreen.screens.first?.frame},
         windowAtPoint:@escaping (NSPoint)->Int={NSWindow.windowNumber(at:$0,belowWindowWithWindowNumber:0)}) {
        self.store=store;self.screens=screens;self.defaultScreen=defaultScreen
        self.primaryScreen=primaryScreen;self.windowAtPoint=windowAtPoint
        preferred=store.load()
        panel=RecordingPanel(contentRect:NSRect(x:0,y:0,width:324,height:116),styleMask:[.nonactivatingPanel,.borderless],backing:.buffered,defer:false)
        super.init()
        panel.isOpaque=false;panel.backgroundColor = .clear;panel.hasShadow=false
        panel.isFloatingPanel=true;panel.level = .floating;panel.hidesOnDeactivate=false
        panel.becomesKeyOnlyIfNeeded=true;panel.isMovable=true
        panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
        panel.contentView=NSHostingView(rootView:StatusPanelView(model:model))
        panel.delegate=self
        panel.onDragEnded={ [weak self] in self?.layout() }
        NotificationCenter.default.addObserver(self,selector:#selector(screensChanged),name:NSApplication.didChangeScreenParametersNotification,object:nil)
    }
    func update(size:NSSize,visible:Bool) {
        self.size=size
        if visible {
            if !panel.isDragging {layout()}
            if !panel.isVisible {panel.orderFrontRegardless()}
        } else {panel.cancelDrag();panel.orderOut(nil)}
    }
    func windowDidMove(_ notification:Notification) {
        guard !isLayingOut else {return}
        let position=PanelPosition(x:panel.frame.minX,y:panel.frame.minY)
        guard preferred != position else {return}
        preferred=position;store.save(position)
    }
    func containsPointer(at point:CGPoint) -> Bool {
        guard panel.isVisible,let primary=primaryScreen() else {return false}
        let location=StatusPanelPlacement.appKitPoint(from:point,primaryScreen:primary)
        // 重なった別ウィンドウへのクリックをパネル操作として除外しない。
        return panel.frame.contains(location) && windowAtPoint(location)==panel.windowNumber
    }
    private func layout() {
        isLayingOut=true
        defer {isLayingOut=false}
        let origin=StatusPanelPlacement.origin(preferred:preferred,size:size,screens:screens(),defaultScreen:defaultScreen())
        if preferred==nil {preferred=PanelPosition(x:origin.x,y:origin.y)}
        panel.setFrame(NSRect(origin:origin,size:size),display:panel.isVisible)
    }
    @objc private func screensChanged() {
        if panel.isVisible,!panel.isDragging {layout()}
    }
}
