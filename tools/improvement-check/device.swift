// 明示実行専用。マイクは数値だけを記録し、文字発行はこのプロセスの固定テスト欄だけに行う。
import AppKit
import AVFoundation
import ApplicationServices
import Speech
import ForblazeCore
import ForblazeApplication
@testable import ForblazeMacOS

private struct RangeSample:Codable {
    let kind:String;let issueMS:Double;let reflectedMS:Double
    let deleted:Int;let preserved:Int;let completed:Bool;let matched:Bool;let waits:Int
}
private struct TapSample:Codable {
    let requested:Int;let frames:[Int];let sampleRate:Double
    let intervalsMS:[Double];let conversionMS:[Double]
}
private struct FixtureCommand:Codable {let sequence:Int;let small:Bool;let check:Bool}
private struct FixtureReply:Codable {let sequence:Int;let matched:Bool}
private func ms(_ value:Duration)->Double {
    Double(value.components.seconds)*1000+Double(value.components.attoseconds)/1e15
}
@MainActor private final class DeviceDelegate:NSObject,NSApplicationDelegate {
    var window:NSWindow?
    private var fixtureTimer:Timer?
    func applicationDidFinishLaunching(_ notification:Notification) {
        Task {
            do {
                let args=CommandLine.arguments
                guard args.count==3 else {throw failure("arguments")}
                if args[1]=="--fixture" {try fixture(URL(fileURLWithPath:args[2]));return}
                let output=URL(fileURLWithPath:args[2])
                guard !FileManager.default.fileExists(atPath:output.path) else {throw failure("output-exists")}
                let data:Data
                if args[1]=="--tap" {data=try JSONEncoder().encode(await tap())}
                else if args[1]=="--range" {data=try JSONEncoder().encode(await ranges(directory:output.deletingLastPathComponent()))}
                else {throw failure("mode")}
                try data.write(to:output,options:.atomic)
                NSApplication.shared.terminate(nil)
            } catch {
                FileHandle.standardError.write(Data("実機比較を完了できませんでした: \((error as NSError).domain) / \((error as NSError).code)\n".utf8))
                exit(1)
            }
        }
    }
    private func tap() async throws -> [TapSample] {
        guard AVCaptureDevice.authorizationStatus(for:.audio) == .authorized else {throw failure("microphone-not-authorized")}
        let module=ApplePermissionService.module(farField:true)
        guard let target=await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:[module]) else {throw failure("format")}
        var samples:[TapSample]=[]
        for size in [4096,2048,1024,512] {
            let engine=AVAudioEngine(),gate=AudioGate()
            let node=engine.inputNode,format=node.outputFormat(forBus:0)
            let stream=AsyncThrowingStream<AudioSamples,Error>.makeStream(bufferingPolicy:.bufferingOldest(32))
            let converter=try AudioConversion(target:AudioFormatDescription(target))
            let read=Task { () throws -> TapSample in
                var frames:[Int]=[],intervals:[Double]=[],conversions:[Double]=[],previous:Double?
                for try await frame in stream.stream {
                    frames.append(frame.channels.first?.count ?? 0)
                    if let time=frame.timing?.tapTime {
                        if let previous {intervals.append((time-previous)*1000)}
                        previous=time
                    }
                    let start=ContinuousClock.now
                    _=try await converter.convert(frame)
                    conversions.append(ms(start.duration(to:.now)))
                }
                _=try await converter.finish()
                return TapSample(requested:size,frames:frames,sampleRate:format.sampleRate,intervalsMS:intervals,conversionMS:conversions)
            }
            gate.set(true)
            node.installTap(onBus:0,bufferSize:AVAudioFrameCount(size),format:format,block:AudioTapBridge.callback(gate:gate,samples:stream.continuation))
            do {
                engine.prepare();try engine.start()
                try await ContinuousClock().sleep(for:.seconds(3))
                gate.set(false);node.removeTap(onBus:0);engine.stop();engine.reset();stream.continuation.finish()
                samples.append(try await read.value)
            } catch {
                gate.set(false);node.removeTap(onBus:0);engine.stop();stream.continuation.finish();read.cancel()
                _=try? await read.value;throw error
            }
        }
        return samples
    }
    private func fixture(_ directory:URL) throws {
        let window=NSWindow(contentRect:NSRect(x:250,y:250,width:600,height:260),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        self.window=window
        window.title="forblaze 局所置換の検証（固定テキスト）"
        let text=NSTextView(frame:NSRect(x:0,y:0,width:600,height:260))
        text.isRichText=false;text.isAutomaticTextReplacementEnabled=false;text.isAutomaticSpellingCorrectionEnabled=false
        window.contentView=text;window.makeKeyAndOrderFront(nil);window.makeFirstResponder(text)
        NSApplication.shared.activate(ignoringOtherApps:true)
        var handled=0
        fixtureTimer=Timer.scheduledTimer(withTimeInterval:0.01,repeats:true) {_ in
            MainActor.assumeIsolated {
                guard let data=try? Data(contentsOf:directory.appendingPathComponent("command.json")),
                      let command=try? JSONDecoder().decode(FixtureCommand.self,from:data),command.sequence>handled else {return}
                handled=command.sequence
                let suffix=String(repeating:"あ",count:command.small ? 20:40)
                let original="検証文、"+suffix,expected="検証文。"+suffix
                if !command.check {text.string=original;text.setSelectedRange(NSRange(location:original.utf16.count,length:0))}
                let matched=text.string==expected && text.selectedRange()==NSRange(location:expected.utf16.count,length:0)
                let reply=FixtureReply(sequence:command.sequence,matched:matched)
                try? JSONEncoder().encode(reply).write(to:directory.appendingPathComponent("reply.json"),options:.atomic)
            }
        }
        try Data("ready".utf8).write(to:directory.appendingPathComponent("ready"),options:.atomic)
    }
    private func ranges(directory:URL) async throws -> [RangeSample] {
        guard AXIsProcessTrusted() else {throw failure("accessibility-not-authorized")}
        // AppKitのAXコールバックは対象アプリのMain threadで動く必要があるため、発行側と入力欄を分離する。
        let ipc=directory.appendingPathComponent("fixture-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:ipc,withIntermediateDirectories:true)
        let process=Process()
        process.executableURL=URL(fileURLWithPath:CommandLine.arguments[0])
        process.arguments=["--fixture",ipc.path]
        try process.run()
        defer {if process.isRunning {process.terminate()}}
        let readyDeadline=ContinuousClock.now.advanced(by:.seconds(3))
        while !FileManager.default.fileExists(atPath:ipc.appendingPathComponent("ready").path) {
            guard process.isRunning,ContinuousClock.now<readyDeadline else {throw failure("fixture-start")}
            try await ContinuousClock().sleep(for:.milliseconds(20))
        }
        try await ContinuousClock().sleep(for:.milliseconds(300))
        let focus=AXFocusService(),sink=CGEventTextSink(focus:focus)
        let snapshot=await focus.read()
        let fixturePID=process.processIdentifier
        guard let target=snapshot.target.id,target.process==fixturePID,snapshot.target.permitsInput else {throw failure("fixture-focus")}
        let context=InjectionContext(session:SessionID(),epoch:snapshot.epoch,target:target)
        var sequence=0
        func command(small:Bool,check:Bool) async throws -> Bool {
            sequence += 1
            try JSONEncoder().encode(FixtureCommand(sequence:sequence,small:small,check:check))
                .write(to:ipc.appendingPathComponent("command.json"),options:.atomic)
            let deadline=ContinuousClock.now.advanced(by:.seconds(2))
            while ContinuousClock.now<deadline {
                if let data=try? Data(contentsOf:ipc.appendingPathComponent("reply.json")),
                   let reply=try? JSONDecoder().decode(FixtureReply.self,from:data),reply.sequence==sequence {return reply.matched}
                try await ContinuousClock().sleep(for:.milliseconds(2))
            }
            throw failure("fixture-timeout")
        }
        var samples:[RangeSample]=[]
        for _ in 0..<20 {
            for kind in ["ordinary","large","ordinarySmall","small"] {
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier==fixturePID else {throw failure("focus-changed")}
                let small=kind=="small" || kind=="ordinarySmall"
                let suffix=String(repeating:"あ",count:small ? 20:40)
                let original="検証文、"+suffix,expected="検証文。"+suffix
                _=try await command(small:small,check:false)
                let planned=InjectionPlanner.difference(from:original,to:expected)
                let edit=kind.hasPrefix("ordinary") ? TextEdit(deleteCount:planned.deleteCount,insertion:planned.insertion):planned
                let start=ContinuousClock.now
                let acknowledgment=await sink.send(edit,context:context,permit:{NSWorkspace.shared.frontmostApplication?.processIdentifier==fixturePID})
                let issueMS=ms(start.duration(to:.now))
                let deadline=ContinuousClock.now.advanced(by:.seconds(1))
                var matched=try await command(small:small,check:true)
                while !matched,ContinuousClock.now<deadline {
                    matched=try await command(small:small,check:true)
                }
                samples.append(RangeSample(kind:kind,issueMS:issueMS,reflectedMS:ms(start.duration(to:.now)),
                    deleted:acknowledgment.deleted-acknowledgment.preservedSuffixCount,preserved:acknowledgment.preservedSuffixCount,
                    completed:acknowledgment.completed,matched:matched,waits:acknowledgment.localizedDiagnostic?.waits ?? 0))
                guard matched,acknowledgment.completed else {throw failure("fixture-result")}
            }
        }
        await focus.stop()
        return samples
    }
    private func failure(_ name:String)->NSError {NSError(domain:"forblaze-device-check."+name,code:1)}
}
@main private struct DeviceCheck {
    @MainActor static func main() {
        let app=NSApplication.shared
        app.setActivationPolicy(CommandLine.arguments.contains("--fixture") ? .regular:.prohibited)
        let delegate=DeviceDelegate();app.delegate=delegate;app.run()
    }
}
