import Testing
import AVFoundation
import ForblazeApplication
@testable import ForblazeMacOS

struct SpeechLatencyTests {
    @Test func reportsActualFramesAndCallbackIntervalsEvenWithoutCaptureClock() throws {
        var tracker=SpeechLatencyTracker()
        tracker.frame(captureStart:nil,tapTime:100,duration:0.02,conversionStart:100.003,conversionEnd:100.004,frameLength:960,sampleRate:48000)
        tracker.frame(captureStart:nil,tapTime:100.025,duration:0.02,conversionStart:100.028,conversionEnd:100.029,frameLength:960,sampleRate:48000)
        #expect(tracker.values[.frameLengthP50]==960 && tracker.values[.sampleRateP50]==48000)
        #expect(abs(try #require(tracker.values[.callbackIntervalP95])-25)<0.001)
        #expect(tracker.values[.frameLengthCount]==2 && tracker.values[.callbackIntervalCount]==1)
        #expect(tracker.values[.timelineValid]==0)
    }
    @Test func alignsSpeechWithCaptureTimeAndSeparatesFinalResults() throws {
        var tracker=SpeechLatencyTracker()
        tracker.frame(captureStart:100,tapTime:101.01,duration:1,conversionStart:101.03,conversionEnd:101.04)
        tracker.result(start:0.2,end:0.8,received:101.2,isFinal:false)
        tracker.result(start:0.2,end:0.8,received:101.5,isFinal:true)
        let values=tracker.values
        #expect(abs(try #require(values[.firstSpeechToResult])-1000)<0.001)
        #expect(abs(try #require(values[.interimP95])-400)<0.001)
        #expect(abs(try #require(values[.finalP95])-700)<0.001)
        #expect(abs(try #require(values[.rawQueueP95])-20)<0.001)
        #expect(abs(try #require(values[.conversionP95])-10)<0.001)
        #expect(abs(try #require(values[.captureLagP95])-10)<0.001)
    }
    @Test func missingOrDiscontinuousCaptureTimeNeverProducesFakeZeroLatency() {
        for start in [Double?.none,100] {
            var tracker=SpeechLatencyTracker()
            tracker.frame(captureStart:start,tapTime:101,duration:1,conversionStart:101,conversionEnd:101)
            tracker.frame(captureStart:103,tapTime:104,duration:1,conversionStart:104,conversionEnd:104)
            tracker.result(start:0.2,end:0.8,received:104.5,isFinal:false)
            #expect(tracker.values[.interimP95]==nil)
            #expect(tracker.values[.timelineValid]==0)
            #expect(tracker.values[.unmeasuredResults]==1)
        }
    }
    @Test func futureAndMissingWordRangesAreNotLatencySamples() {
        var tracker=SpeechLatencyTracker()
        tracker.frame(captureStart:100,tapTime:101,duration:1,conversionStart:101,conversionEnd:101)
        tracker.result(start:nil,end:nil,received:101.1,isFinal:false)
        tracker.result(start:0.2,end:2,received:101.1,isFinal:false)
        tracker.result(start:0.2,end:0.8,received:101.2,isFinal:false)
        #expect(tracker.values[.firstSpeechToResult]==nil)
        #expect(tracker.values[.interimCount]==1)
        #expect(tracker.values[.unmeasuredResults]==2)
    }
    @Test func resamplingKeepsTheSourceTimelineWithinTwoMilliseconds() async throws {
        let format=try #require(AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:16000,channels:1,interleaved:false))
        let converter=try AudioConversion(target:AudioFormatDescription(format))
        var input=Array(repeating:Float.zero,count:9600);input[4800]=1
        var output:[Float]=[]
        for offset in stride(from:0,to:input.count,by:2400) {
            if let value=try await converter.convert(AudioSamples(sampleRate:48000,channels:[Array(input[offset..<offset+2400])])) {
                output += Array(UnsafeBufferPointer(start:value.buffer.floatChannelData![0],count:Int(value.buffer.frameLength)))
            }
        }
        for value in try await converter.finish() {output += Array(UnsafeBufferPointer(start:value.buffer.floatChannelData![0],count:Int(value.buffer.frameLength)))}
        let peak=try #require(output.indices.max(by:{abs(output[$0])<abs(output[$1])}))
        #expect(abs(Double(peak)/16000-0.1)<0.002)
    }
}
