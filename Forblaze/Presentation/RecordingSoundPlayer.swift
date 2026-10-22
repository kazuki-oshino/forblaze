import AppKit

@MainActor protocol RecordingSoundPlayback:AnyObject {
    var hasReachedEnd:Bool {get}
    func play(completion:@escaping ()->Void)->Bool
    func stop()
}

/// 同梱した短い音だけを再生する。録音の所有権やフォーカスは変更しない。
@MainActor final class RecordingSoundPlayer {
    private let makeSound:(RecordingSoundCue)->(any RecordingSoundPlayback)?
    private var current:(any RecordingSoundPlayback)?
    private var endMonitor:Task<Void,Never>?
    private var pendingCompletion:(()->Void)?
    convenience init(bundle:Bundle = .main) {
        let start=bundle.url(forResource:"recording-start",withExtension:"wav").flatMap {try? Data(contentsOf:$0)}
        let stop=bundle.url(forResource:"recording-stop",withExtension:"wav").flatMap {try? Data(contentsOf:$0)}
        self.init(makeSound:{cue in (cue == .start ? start:stop).flatMap {NativeRecordingSound(data:$0)}})
    }
    init(makeSound:@escaping (RecordingSoundCue)->(any RecordingSoundPlayback)?) {self.makeSound=makeSound}
    deinit {endMonitor?.cancel()}
    func play(_ cue:RecordingSoundCue,completion:@escaping ()->Void = {}) {
        let previous=current
        endMonitor?.cancel();endMonitor=nil;pendingCompletion=nil
        current=nil;previous?.stop()
        guard let sound=makeSound(cue) else {completion();return}
        // 再生ごとに別の音を使い、停止後に届いた旧再生の通知を区別する。
        current=sound
        pendingCompletion=completion
        let finished={ [weak self,weak sound] in
            guard let self,let sound,self.current === sound else {return}
            self.endMonitor?.cancel();self.endMonitor=nil
            let completed=self.pendingCompletion
            self.pendingCompletion=nil
            self.current=nil
            completed?()
        }
        guard sound.play(completion:finished) else {finished();return}
        guard cue == .start,current === sound else {return}
        // NSSoundの完了通知には余分な遅れがあるため、開始音だけ再生位置も見る。
        // 音は通知が届くまで保持し、バッファの再生を途中で止めない。
        endMonitor=Task { [weak self,weak sound] in
            while !Task.isCancelled {
                guard let sound else {return}
                if sound.hasReachedEnd {
                    self?.reportEnd(of:sound)
                    return
                }
                do {try await Task.sleep(for:.milliseconds(5))} catch {return}
            }
        }
    }
    private func reportEnd(of sound:any RecordingSoundPlayback) {
        guard current === sound else {return}
        let completed=pendingCompletion
        pendingCompletion=nil
        completed?()
    }
}

@MainActor private final class NativeRecordingSound:NSObject,NSSoundDelegate,RecordingSoundPlayback {
    private let sound:NSSound
    private var completion:(()->Void)?
    var hasReachedEnd:Bool {sound.duration>0 && sound.currentTime>=sound.duration}
    init?(data:Data) {
        guard let sound=NSSound(data:data) else {return nil}
        self.sound=sound;super.init()
    }
    func play(completion:@escaping ()->Void)->Bool {
        self.completion=completion;sound.delegate=self
        return sound.play()
    }
    func stop() {completion=nil;sound.delegate=nil;sound.stop()}
    func sound(_ sound:NSSound,didFinishPlaying flag:Bool) {
        let completed=completion
        completion=nil;sound.delegate=nil
        completed?()
    }
}
