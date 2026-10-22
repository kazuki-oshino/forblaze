import Testing

@MainActor private final class SoundPlaybackFake:RecordingSoundPlayback {
    var starts=true
    var hasReachedEnd=false
    var completed:(()->Void)?
    var stopped=false
    func play(completion:@escaping ()->Void)->Bool {completed=completion;return starts}
    func stop() {stopped=true}
}
@MainActor struct RecordingSoundPlayerTests {
    @Test func startCueReleasesVolumeWaitAtItsEndBeforeDelayedDelegateNotification() async throws {
        let sound=SoundPlaybackFake(),player=RecordingSoundPlayer(makeSound:{_ in sound})
        var completions=0
        player.play(.start) {completions+=1}
        try await Task.sleep(for:.milliseconds(20))
        #expect(completions == 0)
        sound.hasReachedEnd=true
        for _ in 0..<40 where completions == 0 {try await Task.sleep(for:.milliseconds(5))}
        #expect(completions == 1)
        // 完了通知が遅れても二重に呼ばず、再生自体を途中で止めない。
        #expect(!sound.stopped)
        sound.completed?();sound.completed?()
        #expect(completions == 1)
    }
    @Test func stoppingDuringStartCueCancelsItsPositionWait() async throws {
        let first=SoundPlaybackFake(),second=SoundPlaybackFake()
        let player=RecordingSoundPlayer(makeSound:{$0 == .start ? first:second})
        var completions=0
        player.play(.start) {completions+=1}
        player.play(.stop)
        first.hasReachedEnd=true
        try await Task.sleep(for:.milliseconds(30))
        #expect(completions == 0 && first.stopped)
    }
    @Test func canceledPlaybackCannotCompleteANewerSound() {
        let first=SoundPlaybackFake(),second=SoundPlaybackFake()
        let player=RecordingSoundPlayer(makeSound:{$0 == .start ? first:second})
        var firstCompleted=0,secondCompleted=0
        player.play(.start) {firstCompleted+=1}
        player.play(.stop) {secondCompleted+=1}
        first.completed?()
        #expect(first.stopped && firstCompleted == 0 && secondCompleted == 0)
        second.completed?();second.completed?()
        #expect(firstCompleted == 0 && secondCompleted == 1)
    }
    @Test func missingAndUnplayableSoundsCompleteWithoutWaitingForever() {
        var completions=0
        RecordingSoundPlayer(makeSound:{_ in nil}).play(.start) {completions+=1}
        let sound=SoundPlaybackFake();sound.starts=false
        RecordingSoundPlayer(makeSound:{_ in sound}).play(.start) {completions+=1}
        #expect(completions == 2)
    }
    @Test func playbackFailureStillReleasesTheVolumeWait() {
        let sound=SoundPlaybackFake(),player=RecordingSoundPlayer(makeSound:{_ in sound})
        var completions=0
        player.play(.start) {completions+=1}
        sound.completed?()
        #expect(completions == 1)
    }
}
