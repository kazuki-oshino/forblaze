import AppKit
import Testing
import ForblazeCore

@MainActor struct BlazeOverlayTests {
    @Test func applicationShutdownCannotRestartPreparationOnALateRefresh() async {
        _=NSApplication.shared
        let model=DictationViewModel(toggle:{})
        let anchor=RecordingPanel(contentRect:.zero,styleMask:[.nonactivatingPanel,.borderless],backing:.buffered,defer:false)
        let controller=BlazeOverlayController(model:model,anchor:anchor)
        controller.shutdown(permanently:true)
        model.forblazeMode=true;controller.refresh()
        #expect(!controller.isPreparing && controller.panel == nil)
    }
    @Test func offDoesNotPrepareGPUAndOverlayNeverTakesInput() async throws {
        _=NSApplication.shared
        let model=DictationViewModel(toggle:{})
        let anchor=RecordingPanel(contentRect:NSRect(x:100,y:100,width:324,height:116),styleMask:[.nonactivatingPanel,.borderless],backing:.buffered,defer:false)
        let controller=BlazeOverlayController(model:model,anchor:anchor)
        defer {controller.shutdown()}
        controller.refresh()
        #expect(!controller.isPreparing && controller.panel == nil)
        model.forblazeMode=true;controller.refresh();await controller.waitUntilPrepared()
        let panel=try #require(controller.panel)
        #expect(panel.ignoresMouseEvents && !panel.canBecomeKey && !panel.canBecomeMain && !panel.isOpaque)
        #expect(!panel.isVisible && controller.metalView?.isPaused == true)
        model.forblazeMode=false;controller.refresh()
        #expect(controller.panel == nil && !controller.isPreparing)
    }
    @Test func reducedMotionNeverPreparesOverlayAndFailedPreparationFallsBack() async {
        _=NSApplication.shared
        let model=DictationViewModel(toggle:{});model.forblazeMode=true
        let anchor=RecordingPanel(contentRect:.zero,styleMask:[.nonactivatingPanel,.borderless],backing:.buffered,defer:false)
        var reduce=true
        let controller=BlazeOverlayController(model:model,anchor:anchor,reduceMotion:{reduce},prepareResources:{throw BlazeRenderError.deviceUnavailable})
        defer {controller.shutdown()}
        controller.refresh();#expect(!controller.isPreparing && controller.panel == nil)
        reduce=false;controller.refresh();await controller.waitUntilPrepared()
        #expect(controller.preparationFailed && controller.panel == nil)
        controller.refresh();#expect(!controller.isPreparing)
        model.forblazeMode=false;controller.refresh();#expect(!controller.preparationFailed)
    }
    @Test func geometryMapsScreenOriginsAndCapsRetinaRenderSize() {
        let frame=NSRect(x:-1440,y:900,width:1440,height:900)
        let anchor=NSRect(x:-400,y:960,width:324,height:116)
        let origin=BlazeGeometry.origin(anchor:anchor,screen:frame)
        #expect(abs(origin.x-Float(1202.0/1440))<0.0001)
        #expect(abs(origin.y-Float(118.0/900))<0.0001)
        let size=BlazeGeometry.drawableSize(points:NSSize(width:3840,height:2160),scale:2,pixelBudget:2_000_000)
        #expect(size.width*size.height<=2_000_000)
        #expect(abs(size.width/size.height-3840.0/2160)<0.005)
    }
}
