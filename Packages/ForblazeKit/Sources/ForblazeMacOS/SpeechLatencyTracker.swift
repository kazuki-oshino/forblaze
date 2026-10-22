import AVFoundation
import ForblazeApplication

enum AudioHostClock {
    static var now:Double {AVAudioTime.seconds(forHostTime:mach_absolute_time())}
}
struct AudioSampleTiming:Sendable {
    let captureStart:Double?
    let tapTime:Double
}

/// AnalyzerInputの連続した時刻0と、最初のマイクサンプルのhost timeを対応付ける。
/// 単語時刻とリサンプルに由来する誤差を含む推定値。欠落・不連続は計測不能にする。
struct SpeechLatencyTracker {
    private var origin:Double?
    private var sourceDuration=0.0
    private var valid=true
    private var sawResult=false
    private var first:Double?
    private var unmeasured=0
    private var interim=LatencyWindow(),final=LatencyWindow()
    private var captureLag=LatencyWindow(),rawQueue=LatencyWindow(),conversion=LatencyWindow()
    private var frames=LatencyWindow(),rates=LatencyWindow(),intervals=LatencyWindow()
    private var previousTap:Double?
    mutating func frame(captureStart:Double?,tapTime:Double,duration:Double,conversionStart:Double,conversionEnd:Double,frameLength:Int?=nil,sampleRate:Double?=nil) {
        if let frameLength,frameLength>0 {frames.append(Double(frameLength))}
        if let sampleRate,sampleRate>0 {rates.append(sampleRate)}
        if tapTime.isFinite {
            if let previousTap {intervals.append((tapTime-previousTap)*1000)}
            previousTap=tapTime
        }
        rawQueue.append((conversionStart-tapTime)*1000)
        conversion.append((conversionEnd-conversionStart)*1000)
        guard duration.isFinite,duration>0,let captureStart,captureStart.isFinite,tapTime.isFinite else {valid=false;return}
        if origin==nil,sourceDuration==0 {origin=captureStart}
        if let origin,abs(captureStart-(origin+sourceDuration))>0.01 {valid=false}
        sourceDuration += duration
        captureLag.append((tapTime-captureStart-duration)*1000)
    }
    mutating func result(start:Double?,end:Double?,received:Double,isFinal:Bool) {
        let isFirst = !sawResult;sawResult=true
        guard valid,let origin,let start,let end,start.isFinite,end.isFinite,received.isFinite,
              start>=0,end>start,end<=sourceDuration+0.002,received>=origin+end else {
            unmeasured=min(1_000_000,unmeasured+1);return
        }
        if isFirst {first=(received-origin-start)*1000}
        if isFinal {final.append((received-origin-end)*1000)}
        else {interim.append((received-origin-end)*1000)}
    }
    var values:[LatencyField:Double] {
        var fields:[LatencyField:Double]=[.timelineValid:valid && origin != nil ? 1:0,.unmeasuredResults:Double(unmeasured)]
        if let first {fields[.firstSpeechToResult]=first}
        interim.store(in:&fields,keys:(.interimP50,.interimP95,.interimMax,.interimCount))
        final.store(in:&fields,keys:(.finalP50,.finalP95,.finalMax,.finalCount))
        captureLag.store(in:&fields,keys:(.captureLagP50,.captureLagP95,.captureLagMax,.captureLagCount))
        rawQueue.store(in:&fields,keys:(.rawQueueP50,.rawQueueP95,.rawQueueMax,.rawQueueCount))
        conversion.store(in:&fields,keys:(.conversionP50,.conversionP95,.conversionMax,.conversionCount))
        frames.store(in:&fields,keys:(.frameLengthP50,.frameLengthP95,.frameLengthMax,.frameLengthCount))
        rates.store(in:&fields,keys:(.sampleRateP50,.sampleRateP95,.sampleRateMax,.sampleRateCount))
        intervals.store(in:&fields,keys:(.callbackIntervalP50,.callbackIntervalP95,.callbackIntervalMax,.callbackIntervalCount))
        return fields
    }
}
