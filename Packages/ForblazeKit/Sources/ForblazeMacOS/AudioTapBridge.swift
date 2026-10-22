import AVFoundation
import ForblazeCore
/// リアルタイムコールバックがactorの状態へ触れず、値のコピーだけを渡す。
enum AudioTapBridge {
    static func callback(gate:AudioGate,samples:AsyncThrowingStream<AudioSamples,Error>.Continuation,peak:StreamQueuePeak?=nil) -> @Sendable (AVAudioPCMBuffer,AVAudioTime)->Void {
        { buffer,time in receive(buffer,gate:gate,samples:samples,peak:peak,time:time) }
    }
    static func receive(_ buffer:AVAudioPCMBuffer,gate:AudioGate,samples:AsyncThrowingStream<AudioSamples,Error>.Continuation,peak:StreamQueuePeak?=nil,time:AVAudioTime?=nil) {
            guard gate.isOpen else {return}
            let tapTime=AudioHostClock.now
            let captureStart=time.flatMap {$0.isHostTimeValid ? AVAudioTime.seconds(forHostTime:$0.hostTime):nil}
            guard buffer.frameLength<=16384,buffer.format.channelCount<=8,buffer.format.sampleRate.isFinite,buffer.format.sampleRate>0 else {
                gate.set(false);samples.finish(throwing:SessionFailure.audioDevice);return
            }
            guard let pointers=buffer.floatChannelData else {samples.finish(throwing:SessionFailure.audioDevice);return}
            let count=Int(buffer.frameLength),stride=Int(buffer.stride)
            let values=(0..<Int(buffer.format.channelCount)).map { channel in
                (0..<count).map {pointers[channel][$0*stride]}
            }
            switch samples.yield(AudioSamples(sampleRate:buffer.format.sampleRate,channels:values,timing:.init(captureStart:captureStart,tapTime:tapTime))) {
            case .enqueued(let remaining):peak?.observe(remainingCapacity:remaining)
            case .dropped:
                peak?.observe(remainingCapacity:0)
                gate.set(false);samples.finish(throwing:SessionFailure.audioDevice)
            case .terminated:break
            @unknown default:break
            }
    }
}
