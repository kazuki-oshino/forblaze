import Testing
import CoreGraphics
import ForblazeCore
import ForblazeApplication
@testable import ForblazeMacOS
@MainActor struct ManualInputTests {
    @Test func onlyPrimaryClicksOnTheVisiblePanelPreserveRecording() {
        let monitor=CGEventTriggerMonitor()
        var interruptions=0
        monitor.onManualInput={interruptions+=1}
        let panel=CGRect(x:100,y:200,width:324,height:116)
        monitor.preservesRecordingAtPoint={panel.contains($0)}
        #expect(monitor.processPointer(editing:true,location:CGPoint(x:150,y:250)))
        #expect(interruptions==0)
        #expect(monitor.processPointer(editing:true,location:CGPoint(x:10,y:20)))
        #expect(interruptions==1)
        _=monitor.processPointer(editing:true,location:CGPoint(x:150,y:250),isPrimary:false)
        #expect(interruptions==2)
        _=monitor.processPointer(editing:true)
        #expect(interruptions==3)
        monitor.preservesRecordingAtPoint=nil
        _=monitor.processPointer(editing:true,location:CGPoint(x:150,y:250))
        #expect(interruptions==4)
    }
    @Test func interruptionHappensBeforeReturningOriginalEvent() throws {
        let monitor=CGEventTriggerMonitor();try monitor.apply(.defaultBinding,revision:.init(1));monitor.setEnabled(true)
        var order:[String]=[];monitor.onManualInput={order.append("interrupted")};monitor.onToggle={_ in order.append("toggle")}
        for (code,flags) in [(UInt16(0),UInt64(0)),(36,0),(36,1),(36,2),(123,0),(51,0),(9,2)] {
            order=[]
            let decision=monitor.process(.init(.down,code,modifiers:flags,revision:.init(1)));order.append("return")
            #expect(decision == .pass && order==["interrupted","return"])
            _=monitor.process(.init(.up,code,revision:.init(1)))
        }
        order=[];let trigger=monitor.process(.init(.down,100,revision:.init(1)))
        #expect(trigger == .toggle && order==["toggle"])
        _=monitor.process(.init(.up,100,revision:.init(1)))
        order=[];let own=monitor.process(.init(.down,0,revision:.init(1)),marker:InjectionMarker.value)
        #expect(own == .pass && order.isEmpty && monitor.keysReleased)
        let mouse=monitor.processPointer(editing:true);#expect(mouse && order==["interrupted"])
        order=[];_=monitor.processPointer(marker:InjectionMarker.value,editing:true);_=monitor.processPointer(editing:false)
        #expect(order.isEmpty)
        _=monitor.process(.init(.down,0,revision:.init(1)),marker:42)
        #expect(order==["interrupted"])
    }
}
