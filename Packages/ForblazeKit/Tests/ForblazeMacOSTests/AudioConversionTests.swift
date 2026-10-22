import Testing
import AVFoundation
import ForblazeCore
@testable import ForblazeMacOS
struct AudioConversionTests {
    @Test(arguments:[48000.0,44100.0,16000.0])
    func finishingPreservesTheAcceptedAudioDurationAndRunsOnlyOnce(inputRate:Double) async throws {
        let format=try #require(AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:16000,channels:1,interleaved:false))
        let converter=try AudioConversion(target:AudioFormatDescription(format))
        let inputCount=Int(inputRate/10)
        var convertedFrames=0
        for offset in stride(from:0,to:inputCount,by:4096) {
            let samples=Array(repeating:Float(0.1),count:min(4096,inputCount-offset))
            convertedFrames+=Int(try await converter.convert(.init(sampleRate:inputRate,channels:[samples]))?.buffer.frameLength ?? 0)
        }
        let tail=try await converter.finish()
        convertedFrames+=tail.reduce(0) {$0+Int($1.buffer.frameLength)}
        #expect(convertedFrames==1600)
        #expect(try await converter.finish().isEmpty)
        await #expect(throws:SessionFailure.audioDevice) {
            _=try await converter.convert(.init(sampleRate:inputRate,channels:[[0.1]]))
        }
    }

    @Test func finishingBeforeAnyAudioHasNoOutput() async throws {
        let format=try #require(AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:16000,channels:1,interleaved:false))
        let converter=try AudioConversion(target:AudioFormatDescription(format))
        #expect(try await converter.finish().isEmpty)
        #expect(try await converter.finish().isEmpty)
    }

    @Test func convertsSamplesAndRejectsDeviceFormatChange() async throws {
        let format=AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:16000,channels:1,interleaved:false)!
        let converter=try AudioConversion(target:AudioFormatDescription(format))
        let samples=Array(repeating:Float(0.1),count:4096)
        let output=try await converter.convert(AudioSamples(sampleRate:48000,channels:[samples]))
        #expect(output?.buffer.format.sampleRate == 16000)
        #expect((output?.buffer.frameLength ?? 0)>0)
        do { _=try await converter.convert(AudioSamples(sampleRate:48000,channels:[samples,samples]));Issue.record("デバイス形式変更は終了する") }
        catch {}
        do { _=try await converter.convert(AudioSamples(sampleRate:0,channels:[[]]));Issue.record("不正な音声形式") }
        catch {}
    }
}
