import CoreAudio
import OSLog
import ForblazeApplication

@MainActor protocol OutputVolumeDeviceAccess:AnyObject {
    func defaultOutputDevice() throws -> UInt32
    func volume(of device:UInt32) throws -> Float
    func setVolume(_ value:Float,of device:UInt32) throws
}

/// 変更した機器と元の音量だけを保持する。出力先の切り替えや手動操作は監視しない。
@MainActor public final class SystemOutputVolumeControl:OutputVolumeControl {
    private let device:any OutputVolumeDeviceAccess
    private var saved:(device:UInt32,volume:Float)?
    private let logger=Logger(subsystem:"dev.kazuki-oshino.forblaze",category:"OutputVolume")
    public convenience init() {self.init(device:CoreAudioOutputVolumeDevice())}
    init(device:any OutputVolumeDeviceAccess) {self.device=device}

    public func silence() {
        // 復元失敗時も元の音量を上書きしない。
        guard saved == nil else {return}
        do {
            let id=try device.defaultOutputDevice()
            let volume=try device.volume(of:id)
            saved=(id,volume)
            try device.setVolume(0,of:id)
        } catch {
            logger.error("出力音量を0にできませんでした")
            restore()
        }
    }

    public func restore() {
        guard let saved else {return}
        do {
            try device.setVolume(saved.volume,of:saved.device)
            self.saved=nil
        } catch {
            // 待機への遷移・次の停止・アプリ終了時にも復元を試す。
            logger.error("出力音量の復元に失敗しました。元の音量を保持して再試行します")
        }
    }
}

@MainActor private final class CoreAudioOutputVolumeDevice:OutputVolumeDeviceAccess {
    private enum Failure:Error {case unavailable,status(OSStatus)}
    private func address(_ selector:AudioObjectPropertySelector,scope:AudioObjectPropertyScope)->AudioObjectPropertyAddress {
        .init(mSelector:selector,mScope:scope,mElement:kAudioObjectPropertyElementMain)
    }
    func defaultOutputDevice() throws -> UInt32 {
        var property=address(kAudioHardwarePropertyDefaultOutputDevice,scope:kAudioObjectPropertyScopeGlobal)
        var id=AudioDeviceID(kAudioObjectUnknown),size=UInt32(MemoryLayout<AudioDeviceID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&property,0,nil,&size,&id))
        guard id != kAudioObjectUnknown else {throw Failure.unavailable}
        return id
    }
    func volume(of device:UInt32) throws -> Float {
        var property=address(kAudioDevicePropertyVolumeScalar,scope:kAudioObjectPropertyScopeOutput)
        var writable:DarwinBoolean=false
        try check(AudioObjectIsPropertySettable(device,&property,&writable))
        guard writable.boolValue else {throw Failure.unavailable}
        var value:Float32=0,size=UInt32(MemoryLayout<Float32>.size)
        try check(AudioObjectGetPropertyData(device,&property,0,nil,&size,&value))
        guard value.isFinite,(0...1).contains(value) else {throw Failure.unavailable}
        return value
    }
    func setVolume(_ value:Float,of device:UInt32) throws {
        var property=address(kAudioDevicePropertyVolumeScalar,scope:kAudioObjectPropertyScopeOutput),value=value
        try check(AudioObjectSetPropertyData(device,&property,0,nil,UInt32(MemoryLayout<Float32>.size),&value))
    }
    private func check(_ status:OSStatus) throws {
        guard status == noErr else {throw Failure.status(status)}
    }
}
