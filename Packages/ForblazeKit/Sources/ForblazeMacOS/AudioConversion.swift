import AVFoundation
import Synchronization
import Speech
import ForblazeCore
final class AudioGate: Sendable {
    private let state=Mutex(false)
    func set(_ value:Bool) {state.withLock {$0=value}}
    var isOpen:Bool {state.withLock {$0}}
    func takeOnce() -> Bool {state.withLock {value in guard !value else {return false};value=true;return true}}
}
struct AudioSamples: Sendable {
    let sampleRate: Double
    let channels: [[Float]]
    var timing:AudioSampleTiming?=nil
}
struct AudioFormatDescription: Sendable {
    let sampleRate: Double
    let channels: UInt32
    let commonFormat: UInt
    let interleaved: Bool
    init(_ format: AVAudioFormat) {
        sampleRate=format.sampleRate;channels=format.channelCount
        commonFormat=format.commonFormat.rawValue;interleaved=format.isInterleaved
    }
}
/// converterとPCMバッファをこのactorだけで生成・所有する。
/// callbackの借用バッファはコピーしたFloat値として受け取る。
actor AudioConversion {
    private let output: AVAudioFormat
    private var converter: AVAudioConverter?
    private var inputRate: Double?
    private var inputChannels: Int?
    private var finished=false
    init(target: AudioFormatDescription) throws {
        guard let kind=AVAudioCommonFormat(rawValue:target.commonFormat),
              let format=AVAudioFormat(commonFormat:kind,sampleRate:target.sampleRate,channels:target.channels,interleaved:target.interleaved) else {throw SessionFailure.audioDevice}
        output=format
    }
    func finish() throws -> [AnalyzerInput] {
        guard !finished else {return []}
        finished=true
        guard let converter else {return []}
        var tail:[AnalyzerInput]=[]
        while true {
            try Task.checkCancellation()
            guard let converted=AVAudioPCMBuffer(pcmFormat:output,frameCapacity:4096) else {throw SessionFailure.audioDevice}
            var error:NSError?
            let status=converter.convert(to:converted,error:&error) {_,state in
                state.pointee = .endOfStream;return nil
            }
            guard status != .error,error == nil else {throw SessionFailure.audioDevice}
            if converted.frameLength>0 {tail.append(AnalyzerInput(buffer:converted))}
            if status == .endOfStream {return tail}
            guard converted.frameLength>0 else {throw SessionFailure.audioDevice}
        }
    }
    func convert(_ samples:AudioSamples) throws -> AnalyzerInput? {
        guard !finished,samples.sampleRate>0,let first=samples.channels.first,!first.isEmpty,
              samples.channels.allSatisfy({$0.count==first.count}),
              let format=AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:samples.sampleRate,channels:UInt32(samples.channels.count),interleaved:false),
              let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:UInt32(first.count)),
              let data=buffer.floatChannelData else {throw SessionFailure.audioDevice}
        buffer.frameLength=UInt32(first.count)
        for channel in samples.channels.indices {
            samples.channels[channel].withUnsafeBufferPointer { ptr in data[channel].update(from:ptr.baseAddress!,count:first.count) }
        }
        if converter == nil {converter=AVAudioConverter(from:format,to:output);inputRate=samples.sampleRate;inputChannels=samples.channels.count}
        guard inputRate==samples.sampleRate,inputChannels==samples.channels.count,let converter,
              let converted=AVAudioPCMBuffer(pcmFormat:output,frameCapacity:UInt32(Double(first.count)*output.sampleRate/samples.sampleRate)+1024) else {throw SessionFailure.audioDevice}
        let delivery=AudioGate(), input=AnalyzerInput(buffer:buffer)
        var error:NSError?
        let status=converter.convert(to:converted,error:&error) {_,state in
            guard delivery.takeOnce() else {state.pointee = .noDataNow;return nil}
            state.pointee = .haveData;return input.buffer
        }
        guard status != .error,error == nil else {throw SessionFailure.audioDevice}
        guard converted.frameLength>0 else {return nil}
        // AnalyzerInputはSDKがSendableを保証する。以後このバッファを変更しない。
        return AnalyzerInput(buffer:converted)
    }
}
