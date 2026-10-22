import AppKit
import MetalKit

@MainActor final class BlazePanel:NSPanel {
    override var canBecomeKey:Bool {false}
    override var canBecomeMain:Bool {false}
}

/// 全画面の演出は、入力を受ける録音パネルから分離する。
@MainActor final class BlazeOverlayController:NSObject {
    private let model:DictationViewModel
    private let anchor:NSPanel
    private let reduceMotion:()->Bool
    private let prepareResources:@Sendable () async throws -> BlazeResources
    private var preparation:Task<Void,Never>?
    private var generation=0
    private var closed=false
    private var displaySleeping=false
    private(set) var preparationFailed=false
    private(set) var panel:BlazePanel?
    private(set) var metalView:BlazeMetalView?
    private(set) var renderer:BlazeRenderer?
    var isPreparing:Bool {preparation != nil}

    init(model:DictationViewModel,anchor:NSPanel,
         reduceMotion:@escaping ()->Bool={NSWorkspace.shared.accessibilityDisplayShouldReduceMotion},
         prepareResources:@escaping @Sendable () async throws -> BlazeResources={try await Task.detached(priority:.utility) {try BlazeResources.make()}.value}) {
        self.model=model;self.anchor=anchor;self.reduceMotion=reduceMotion;self.prepareResources=prepareResources
        super.init()
        NotificationCenter.default.addObserver(self,selector:#selector(geometryChanged),name:NSWindow.didMoveNotification,object:anchor)
        NotificationCenter.default.addObserver(self,selector:#selector(geometryChanged),name:NSWindow.didChangeScreenNotification,object:anchor)
        NotificationCenter.default.addObserver(self,selector:#selector(geometryChanged),name:NSWindow.didChangeBackingPropertiesNotification,object:anchor)
        NotificationCenter.default.addObserver(self,selector:#selector(geometryChanged),name:NSApplication.didChangeScreenParametersNotification,object:nil)
        NSWorkspace.shared.notificationCenter.addObserver(self,selector:#selector(accessibilityChanged),name:NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,object:nil)
        NSWorkspace.shared.notificationCenter.addObserver(self,selector:#selector(displayDidSleep),name:NSWorkspace.screensDidSleepNotification,object:nil)
        NSWorkspace.shared.notificationCenter.addObserver(self,selector:#selector(displayDidWake),name:NSWorkspace.screensDidWakeNotification,object:nil)
    }

    func refresh() {
        guard !closed else {return}
        guard model.forblazeMode else {shutdown();return}
        guard !displaySleeping else {hide();return}
        guard !preparationFailed else {hide();return}
        let intent=BlazePresentation.intent(enabled:true,state:model.state,reduceMotion:reduceMotion())
        if intent == .staticGlow || reduceMotion() {hide();return}
        if renderer == nil {prepare()}
        switch intent {
        case .burning:
            guard let renderer,let view=metalView,let panel else {return}
            guard updateGeometry() else {hide();return}
            renderer.setBurning(true)
            view.isPaused=false
            if !panel.isVisible {
                view.draw()
                panel.order(.below,relativeTo:anchor.windowNumber)
            }
        case .cooling:renderer?.setBurning(false)
        case .hidden,.staticGlow:hide()
        }
    }

    private func prepare() {
        guard preparation == nil,!preparationFailed else {return}
        let generation=self.generation,make=prepareResources
        preparation=Task { [weak self] in
            do {
                let resources=try await make()
                guard !Task.isCancelled,let self,self.generation == generation else {return}
                self.install(resources);self.preparation=nil;self.refresh()
            } catch {
                guard !Task.isCancelled,let self,self.generation == generation else {return}
                self.preparationFailed=true;self.preparation=nil;self.hide()
            }
        }
    }

    private func install(_ resources:BlazeResources) {
        let panel=BlazePanel(contentRect:NSRect(x:0,y:0,width:1,height:1),styleMask:[.nonactivatingPanel,.borderless],backing:.buffered,defer:false)
        panel.isOpaque=false;panel.backgroundColor = .clear;panel.hasShadow=false
        panel.ignoresMouseEvents=true;panel.level=anchor.level;panel.isFloatingPanel=true
        panel.hidesOnDeactivate=false;panel.becomesKeyOnlyIfNeeded=true
        panel.isReleasedWhenClosed=false
        panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary,.ignoresCycle]
        let view=BlazeMetalView(frame:.zero,device:resources.device)
        view.isPaused=true;view.enableSetNeedsDisplay=false;view.autoResizeDrawable=false
        view.colorPixelFormat = .bgra8Unorm;view.clearColor=MTLClearColorMake(0,0,0,0)
        view.wantsLayer=true;view.layer?.isOpaque=false
        view.setAccessibilityElement(false);view.setAccessibilityHidden(true)
        let renderer=BlazeRenderer(resources:resources)
        renderer.level={ [weak model] in model?.level ?? 0 }
        renderer.onFinished={ [weak self] in self?.hide() }
        renderer.onFailure={ [weak self] in self?.preparationFailed=true;self?.hide() }
        view.delegate=renderer;panel.contentView=view
        self.panel=panel;metalView=view;self.renderer=renderer
    }

    @discardableResult private func updateGeometry()->Bool {
        guard let panel,let view=metalView,let renderer,let screen=anchor.screen ?? NSScreen.main else {return false}
        if panel.frame != screen.frame {panel.setFrame(screen.frame,display:false)}
        view.frame=NSRect(origin:.zero,size:screen.frame.size)
        renderer.origin=BlazeGeometry.origin(anchor:anchor.frame,screen:screen.frame)
        renderer.resize(view)
        return true
    }
    @objc private func geometryChanged() {
        guard panel?.isVisible == true else {return}
        if !updateGeometry() {hide()}
    }
    @objc private func accessibilityChanged() {refresh()}
    @objc private func displayDidSleep() {displaySleeping=true;hide()}
    @objc private func displayDidWake() {displaySleeping=false;refresh()}
    func hide() {
        metalView?.isPaused=true;renderer?.stopImmediately();panel?.orderOut(nil)
    }
    func shutdown(permanently:Bool=false) {
        closed=closed || permanently
        generation+=1;preparation?.cancel();preparation=nil
        hide();metalView?.delegate=nil;panel?.contentView=nil;panel?.close()
        renderer=nil;metalView=nil;panel=nil;preparationFailed=false
    }
    func waitUntilPrepared() async {await preparation?.value}
}
