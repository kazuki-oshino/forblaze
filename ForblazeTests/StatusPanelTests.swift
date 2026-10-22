import AppKit
import Testing
import ForblazeApplication
import ForblazeCore
import ForblazeMacOS

@MainActor private final class PanelPositionFake:PanelPositionStore {
    var value:PanelPosition?
    var saves=0
    func load() -> PanelPosition? {value}
    func save(_ position:PanelPosition) {value=position;saves+=1}
}
@MainActor struct StatusPanelTests {
    private let screen=NSRect(x:0,y:24,width:1440,height:852)
    private let size=NSSize(width:324,height:116)
    @Test func mouseDragMovesPanelWithoutBecomingKeyAndStopsOnMouseUp() throws {
        _=NSApplication.shared
        let panel=RecordingPanel(contentRect:NSRect(x:100,y:100,width:324,height:116),styleMask:[.nonactivatingPanel,.borderless],backing:.buffered,defer:false)
        func event(_ type:NSEvent.EventType,_ x:CGFloat,_ y:CGFloat) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with:type,location:NSPoint(x:x,y:y),modifierFlags:[],timestamp:0,windowNumber:panel.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1))
        }
        panel.sendEvent(try event(.leftMouseDown,20,20))
        panel.sendEvent(try event(.leftMouseDragged,220,320))
        #expect(panel.frame.origin==NSPoint(x:300,y:400))
        #expect(!panel.canBecomeKey && !panel.canBecomeMain)
        panel.sendEvent(try event(.leftMouseUp,20,20))
        panel.sendEvent(try event(.leftMouseDragged,120,120))
        #expect(panel.frame.origin==NSPoint(x:300,y:400))
    }
    @Test func placementRestoresAllScreenDirectionsAndClampsDisconnectedScreens() {
        let left=NSRect(x:-1440,y:24,width:1440,height:852)
        let above=NSRect(x:0,y:900,width:1440,height:852)
        let below=NSRect(x:0,y:-900,width:1440,height:852)
        for position in [PanelPosition(x:-1000,y:200),.init(x:100,y:1200),.init(x:100,y:-700)] {
            #expect(StatusPanelPlacement.origin(preferred:position,size:size,screens:[screen,left,above,below],defaultScreen:screen)==NSPoint(x:position.x,y:position.y))
        }
        #expect(StatusPanelPlacement.origin(preferred:nil,size:size,screens:[screen],defaultScreen:screen)==NSPoint(x:1092,y:40))
        #expect(StatusPanelPlacement.origin(preferred:.init(x:-1000,y:200),size:size,screens:[screen],defaultScreen:screen)==NSPoint(x:0,y:200))
        #expect(StatusPanelPlacement.origin(preferred:.init(x:1400,y:850),size:size,screens:[screen],defaultScreen:screen)==NSPoint(x:1116,y:760))
        #expect(StatusPanelPlacement.origin(preferred:.init(x:.nan,y:0),size:size,screens:[screen],defaultScreen:screen)==NSPoint(x:1092,y:40))
    }
    @Test func pointerCoordinatesUsePrimaryScreenEvenOnAnotherDisplay() {
        let primary=NSRect(x:0,y:0,width:1440,height:900)
        #expect(StatusPanelPlacement.appKitPoint(from:CGPoint(x:-1000,y:600),primaryScreen:primary)==NSPoint(x:-1000,y:300))
        #expect(StatusPanelPlacement.appKitPoint(from:CGPoint(x:100,y:-300),primaryScreen:primary)==NSPoint(x:100,y:1200))
    }
    @Test func refreshDuringDragDefersLayoutAndScreenChangesKeepSavedPosition() throws {
        _=NSApplication.shared
        let store=PanelPositionFake();store.value = .init(x:200,y:300)
        var screens=[screen]
        let controller=StatusPanelController(model:DictationViewModel(toggle:{}),store:store,screens:{screens},defaultScreen:{screen})
        defer {controller.panel.orderOut(nil)}
        controller.update(size:size,visible:true)
        func event(_ type:NSEvent.EventType,_ x:CGFloat,_ y:CGFloat) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with:type,location:NSPoint(x:x,y:y),modifierFlags:[],timestamp:0,windowNumber:controller.panel.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1))
        }
        controller.panel.sendEvent(try event(.leftMouseDown,20,20))
        controller.panel.sendEvent(try event(.leftMouseDragged,120,120))
        controller.update(size:NSSize(width:324,height:200),visible:true)
        #expect(controller.panel.frame.origin==NSPoint(x:300,y:400) && controller.panel.frame.height==116)
        controller.panel.sendEvent(try event(.leftMouseUp,20,20))
        #expect(controller.panel.frame.origin==NSPoint(x:300,y:400) && controller.panel.frame.height==200)
        #expect(store.value == .init(x:300,y:400) && store.saves==1)
        screens=[NSRect(x:0,y:24,width:500,height:500)]
        NotificationCenter.default.post(name:NSApplication.didChangeScreenParametersNotification,object:nil)
        #expect(controller.panel.frame.origin==NSPoint(x:176,y:324))
        #expect(store.value == .init(x:300,y:400) && store.saves==1)
        screens=[screen]
        NotificationCenter.default.post(name:NSApplication.didChangeScreenParametersNotification,object:nil)
        #expect(controller.panel.frame.origin==NSPoint(x:300,y:400))
    }
    @Test func draggingPersistsAcrossRefreshResizeHideAndNewController() {
        _=NSApplication.shared
        let store=PanelPositionFake(),model=DictationViewModel(toggle:{})
        let controller=StatusPanelController(model:model,store:store,screens:{[screen]},defaultScreen:{screen})
        defer {controller.panel.orderOut(nil)}
        controller.update(size:size,visible:true)
        #expect(controller.panel.frame.origin==NSPoint(x:1092,y:40))
        #expect(!controller.panel.canBecomeKey && !controller.panel.canBecomeMain && !controller.panel.ignoresMouseEvents)
        controller.panel.setFrameOrigin(NSPoint(x:250,y:300))
        #expect(store.value == .init(x:250,y:300) && store.saves==1)
        controller.update(size:NSSize(width:324,height:200),visible:true)
        #expect(controller.panel.frame.origin==NSPoint(x:250,y:300) && controller.panel.frame.height==200)
        controller.update(size:size,visible:false)
        controller.update(size:size,visible:true)
        #expect(controller.panel.frame.origin==NSPoint(x:250,y:300) && store.saves==1)
        let restored=StatusPanelController(model:model,store:store,screens:{[screen]},defaultScreen:{screen})
        defer {restored.panel.orderOut(nil)}
        restored.update(size:size,visible:true)
        #expect(restored.panel.frame.origin==NSPoint(x:250,y:300))
    }
    @Test func panelClickKeepsSessionButOccludedOrOutsideClicksStopIt() async {
        _=NSApplication.shared
        let trigger=CGEventTriggerMonitor()
        let app=AppComposition(speech:SpeechFake(),clock:ClockFake(),trigger:trigger,store:StoreFake())
        let store=PanelPositionFake();store.value = .init(x:100,y:200)
        var topWindow=0
        let controller=StatusPanelController(model:app.model,store:store,screens:{[screen]},defaultScreen:{screen},
            primaryScreen:{NSRect(x:0,y:0,width:1440,height:900)},windowAtPoint:{_ in topWindow})
        defer {controller.panel.orderOut(nil)}
        trigger.preservesRecordingAtPoint={controller.containsPointer(at:$0)}
        app.session.toggle();await app.session.awaitPreparation()
        let id=app.session.state.session
        controller.update(size:size,visible:true);topWindow=controller.panel.windowNumber
        let inside=CGPoint(x:150,y:650)
        #expect(controller.containsPointer(at:inside))
        _=trigger.processPointer(editing:true,location:inside)
        #expect(app.session.state.phase == .listening && app.session.state.session==id)
        topWindow = -1
        #expect(!controller.containsPointer(at:inside))
        _=trigger.processPointer(editing:true,location:inside)
        #expect(app.session.state.phase == .stopping && app.session.state.permission == .closed)
        await app.session.awaitCleanup()
        controller.update(size:size,visible:false);topWindow=controller.panel.windowNumber
        #expect(!controller.containsPointer(at:inside))
        app.session.toggle();await app.session.awaitPreparation();controller.update(size:size,visible:true)
        _=trigger.processPointer(editing:true,location:CGPoint(x:10,y:10))
        #expect(app.session.state.phase == .stopping)
        await app.session.awaitCleanup()
    }
}
