import Testing
@testable import ForblazeMacOS

@MainActor private final class VolumeDeviceFake:OutputVolumeDeviceAccess {
    var device:UInt32=7
    var values:[UInt32:Float]=[7:0.42,8:0.73]
    var writes:[(UInt32,Float)]=[]
    var readFails=false
    var failedWrites=0
    var appliesBeforeFailure=false
    enum Failure:Error {case unavailable}
    func defaultOutputDevice() throws -> UInt32 {device}
    func volume(of device:UInt32) throws -> Float {
        if readFails {throw Failure.unavailable}
        return values[device]!
    }
    func setVolume(_ value:Float,of device:UInt32) throws {
        writes.append((device,value))
        if failedWrites>0 {
            failedWrites-=1
            if appliesBeforeFailure {values[device]=value}
            throw Failure.unavailable
        }
        values[device]=value
    }
}
@MainActor struct SystemOutputVolumeTests {
    @Test func remembersVolumeOnceAndRestoresTheOriginalDevice() {
        let device=VolumeDeviceFake(),control=SystemOutputVolumeControl(device:device)
        control.restore();#expect(device.writes.isEmpty)
        control.silence();control.silence()
        #expect(device.values[7] == 0 && device.writes.count == 1)
        device.device=8
        control.restore();control.restore()
        #expect(device.values[7] == 0.42 && device.values[8] == 0.73 && device.writes.count == 2)
    }
    @Test func unreadableOrUnsupportedOutputIsNeverChanged() {
        let device=VolumeDeviceFake(),control=SystemOutputVolumeControl(device:device)
        device.readFails=true;control.silence();control.restore()
        #expect(device.writes.isEmpty)
    }
    @Test func failedSilenceRollsBackEvenIfTheDriverAppliedTheChange() {
        let device=VolumeDeviceFake(),control=SystemOutputVolumeControl(device:device)
        device.failedWrites=1;device.appliesBeforeFailure=true
        control.silence()
        #expect(device.values[7] == 0.42 && device.writes.count == 2)
    }
    @Test func failedRestoreKeepsTheOriginalVolumeForRetry() {
        let device=VolumeDeviceFake(),control=SystemOutputVolumeControl(device:device)
        control.silence();device.failedWrites=1;control.restore()
        #expect(device.values[7] == 0)
        control.silence();control.restore()
        #expect(device.values[7] == 0.42)
    }
    @Test func restoresZeroAndUserChangedVolumeWithoutCompoundingAcrossSessions() {
        let device=VolumeDeviceFake(),control=SystemOutputVolumeControl(device:device)
        device.values[7]=0;control.silence();control.restore()
        #expect(device.values[7] == 0)
        device.values[7]=0.63;control.silence();device.values[7]=0.2;control.restore()
        #expect(device.values[7] == 0.63)
        device.values[7]=0.27;control.silence();control.restore()
        #expect(device.values[7] == 0.27)
    }
}
