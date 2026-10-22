// 固定の合成音声を実時間で供給する比較器。マイク・入力欄・個人設定へ接続しない。
import Foundation
import AVFoundation
import Speech
import CoreMedia
@testable import ForblazeMacOS

private struct Job:Codable {let id:String;let path:String;let expected:String;let hints:[String]}
private struct Condition {
    let name:String;let frames:Int;var prewarm=false;var hints=false
}
private struct Event:Codable,Sendable {
    let text:String;let final:Bool;let start:Double;let end:Double;let receivedMS:Double
}
private struct Measurement:Codable {
    let id:String;let condition:String;let repetition:Int;let expected:String
    let frames:Int;let inputRate:Double;let seconds:Double
    let prewarmMS:Double;let readyMS:Double;let totalMS:Double
    let conversionMS:[Double];let events:[Event]
}

@main private struct Comparison {
    static func ms(_ duration:Duration)->Double {
        let c=duration.components;return Double(c.seconds)*1000+Double(c.attoseconds)/1e15
    }
    @MainActor static func main() async {
        do {try await run()} catch {
            FileHandle.standardError.write(Data("比較を完了できませんでした: \((error as NSError).domain) / \((error as NSError).code)\n".utf8))
            exit(1)
        }
    }
    @MainActor private static func run() async throws {
        if CommandLine.arguments.dropFirst()==["--prepare-model"] {
            let module=ApplePermissionService.module(farField:true)
            if let request=try await AssetInventory.assetInstallationRequest(supporting:[module]) {
                try await request.downloadAndInstall()
            }
            print("日本語モデル: \(await AssetInventory.status(forModules:[module]))")
            return
        }
        guard CommandLine.arguments.count==3 else {throw failure("arguments")}
        let jobs=try JSONDecoder().decode([Job].self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
        let output=URL(fileURLWithPath:CommandLine.arguments[2])
        guard !FileManager.default.fileExists(atPath:output.path) else {throw failure("output-exists")}
        FileManager.default.createFile(atPath:output.path,contents:nil)
        let handle=try FileHandle(forWritingTo:output);defer {try? handle.close()}
        let conditions=[
            Condition(name:"baseline",frames:4096),Condition(name:"hints",frames:4096,hints:true),
            Condition(name:"prewarm",frames:4096,prewarm:true),Condition(name:"buffer2048",frames:2048),
            Condition(name:"buffer1024",frames:1024),Condition(name:"buffer512",frames:512)]
        for repetition in 0..<2 {
            for (index,job) in jobs.enumerated() {
                // 順序を反転し、常に同じ条件が先になる偏りを減らす。OSキャッシュは消去しない。
                let order=(repetition+index).isMultiple(of:2) ? conditions:Array(conditions.reversed())
                for condition in order {
                    let value=try await measure(job,condition:condition,repetition:repetition)
                    try handle.write(contentsOf:JSONEncoder().encode(value));try handle.write(contentsOf:Data([10]))
                    print("\(repetition+1) / \(job.id) / \(condition.name): \(value.events.count) results")
                }
            }
        }
    }
    @MainActor private static func measure(_ job:Job,condition:Condition,repetition:Int) async throws -> Measurement {
        let file=try AVAudioFile(forReading:URL(fileURLWithPath:job.path))
        let format=file.processingFormat,seconds=Double(file.length)/format.sampleRate
        let module=ApplePermissionService.module(farField:true)
        let status=await AssetInventory.status(forModules:[module])
        guard status == .installed else {throw failure("model-status-\(status)")}
        guard let target=await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:[module]) else {throw failure("audio-format-unavailable")}
        let analyzer=SpeechAnalyzer(modules:[module],options:condition.prewarm ? .init(priority:.userInitiated,modelRetention:.lingering):nil)
        let watch=Task {
            do {try await ContinuousClock().sleep(for:.seconds(45))} catch {return}
            await analyzer.cancelAndFinishNow()
        }
        defer {watch.cancel()}
        let preparationStart=ContinuousClock.now
        if condition.prewarm {try await analyzer.prepareToAnalyze(in:target)}
        let prewarmMS=condition.prewarm ? ms(preparationStart.duration(to:.now)):0
        let start=ContinuousClock.now
        let context=AnalysisContext()
        context.contextualStrings[.general]=condition.hints ? job.hints:[]
        try await analyzer.setContext(context)
        let converter=try AudioConversion(target:AudioFormatDescription(target))
        let input=AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy:.bufferingOldest(32))
        let results=Task { () throws -> [Event] in
            var events:[Event]=[]
            for try await value in module.results {
                events.append(Event(text:String(value.text.characters),final:value.isFinal,
                                    start:CMTimeGetSeconds(value.range.start),end:CMTimeGetSeconds(CMTimeRangeGetEnd(value.range)),
                                    receivedMS:ms(start.duration(to:.now))))
            }
            return events
        }
        do {
            try await analyzer.start(inputSequence:input.stream)
            let readyMS=ms(start.duration(to:.now)),feedStart=ContinuousClock.now
            var conversions:[Double]=[]
            var supplied=0
            func send(_ converted:AnalyzerInput) throws {
                if case .enqueued=input.continuation.yield(converted) {} else {throw failure("audio-overflow")}
            }
            while file.framePosition<file.length {
                guard let pcm=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:UInt32(condition.frames)) else {throw failure("buffer")}
                try file.read(into:pcm,frameCount:UInt32(condition.frames))
                guard let pointers=pcm.floatChannelData,pcm.frameLength>0 else {throw failure("pcm")}
                let count=Int(pcm.frameLength),stride=Int(pcm.stride)
                let channels=(0..<Int(format.channelCount)).map {channel in
                    (0..<count).map {pointers[channel][$0*stride]}
                }
                supplied += count
                // 実際のtapと同じく、当該バッファの収録が終わった時点で渡す。
                try await ContinuousClock().sleep(until:feedStart.advanced(by:.seconds(Double(supplied)/format.sampleRate)))
                let conversionStart=ContinuousClock.now
                if let value=try await converter.convert(.init(sampleRate:format.sampleRate,channels:channels)) {try send(value)}
                conversions.append(ms(conversionStart.duration(to:.now)))
            }
            for value in try await converter.finish() {try send(value)}
            input.continuation.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            let events=try await results.value
            guard events.contains(where:{$0.final && !$0.text.isEmpty}) else {throw failure("empty-final")}
            let value=Measurement(id:job.id,condition:condition.name,repetition:repetition,expected:job.expected,
                                  frames:condition.frames,inputRate:format.sampleRate,seconds:seconds,
                                  prewarmMS:prewarmMS,readyMS:readyMS,totalMS:ms(start.duration(to:.now)),
                                  conversionMS:conversions,events:events)
            await analyzer.cancelAndFinishNow()
            return value
        } catch {
            input.continuation.finish();results.cancel();await analyzer.cancelAndFinishNow()
            _=try? await results.value;throw error
        }
    }
    static func failure(_ name:String)->NSError {NSError(domain:"forblaze-improvement-check."+name,code:1)}
}
