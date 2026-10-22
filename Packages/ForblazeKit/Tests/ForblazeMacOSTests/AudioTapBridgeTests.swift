import AVFoundation
import Testing
@testable import ForblazeMacOS
struct AudioTapBridgeTests {
    @Test func queuePeakTracksCapacityAndResetsWithoutRetainingFrames() async throws {
        let peak=StreamQueuePeak(capacity:2),gate=AudioGate();gate.set(true)
        let pair=AsyncThrowingStream<AudioSamples,Error>.makeStream(bufferingPolicy:.bufferingOldest(2))
        let format=try #require(AVAudioFormat(standardFormatWithSampleRate:48000,channels:1))
        let buffer=try #require(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:1));buffer.frameLength=1
        AudioTapBridge.receive(buffer,gate:gate,samples:pair.continuation,peak:peak)
        #expect(peak.value==1)
        AudioTapBridge.receive(buffer,gate:gate,samples:pair.continuation,peak:peak)
        #expect(peak.value==2)
        var iterator=pair.stream.makeAsyncIterator();_=try await iterator.next()
        AudioTapBridge.receive(buffer,gate:gate,samples:pair.continuation,peak:peak)
        #expect(peak.value==2)
        peak.observe(remainingCapacity:-100);#expect(peak.value==2)
        peak.reset();peak.observe(remainingCapacity:100);#expect(peak.value==0)
        gate.set(false);AudioTapBridge.receive(buffer,gate:gate,samples:pair.continuation,peak:peak)
        #expect(peak.value==0);pair.continuation.finish()
    }

    @Test func copiedSamplesDoNotFollowBufferMutationAndClosedGateRejects() async throws {
        let gate=AudioGate();gate.set(true)
        let pair=AsyncThrowingStream<AudioSamples,Error>.makeStream(bufferingPolicy:.bufferingOldest(2))
        let format=try #require(AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:48000,channels:1,interleaved:false))
        let buffer=try #require(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:2));buffer.frameLength=2
        buffer.floatChannelData![0][0]=0.5;buffer.floatChannelData![0][1]=0.25
        let time=AVAudioTime(hostTime:AVAudioTime.hostTime(forSeconds:123))
        AudioTapBridge.callback(gate:gate,samples:pair.continuation)(buffer,time)
        buffer.floatChannelData![0][0]=1
        gate.set(false);AudioTapBridge.receive(buffer,gate:gate,samples:pair.continuation)
        pair.continuation.finish();var values:[AudioSamples]=[]
        for try await value in pair.stream {values.append(value)}
        #expect(values.count==1 && values.first?.channels == [[0.5,0.25]])
        #expect(abs(try #require(values.first?.timing?.captureStart)-123)<0.000001)
        #expect(try #require(values.first?.timing?.tapTime)>0)
    }
    @Test func overflowClosesGateAndReportsFailure() async throws {
        let gate=AudioGate();gate.set(true)
        let pair=AsyncThrowingStream<AudioSamples,Error>.makeStream(bufferingPolicy:.bufferingOldest(1))
        let format=try #require(AVAudioFormat(standardFormatWithSampleRate:48000,channels:1))
        let buffer=try #require(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:1));buffer.frameLength=1
        AudioTapBridge.receive(buffer,gate:gate,samples:pair.continuation)
        AudioTapBridge.receive(buffer,gate:gate,samples:pair.continuation)
        #expect(!gate.isOpen)
        pair.continuation.finish()
        await #expect(throws: (any Error).self) {for try await _ in pair.stream {}}
    }
}
