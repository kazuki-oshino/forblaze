import Testing
import ForblazeCore
@MainActor struct DictationViewModelTests {
    @Test func targetFailuresOfferRecoveryOnlyAfterCleanup() {
        let cases:[(TargetIssue,String,String)]=[
            (.unavailable,"入力欄を確認できません","入力したい欄をクリックして、開始キーを押してください"),
            (.noneditable,"この場所には音声入力できません","文字を入力できる欄を選んでください"),
            (.protected,"保護された入力欄には音声入力できません","別の入力欄を選んでください")
        ]
        for (issue,message,help) in cases {
            let model=DictationViewModel(toggle:{});var state=SessionState();let id=SessionID()
            _=state.handle(.toggle(id));_=state.handle(.failed(id,.target(issue)))
            model.update(state:state,preview:"")
            #expect(model.errorText==nil && model.recoveryHelp==nil && model.title=="終了処理中")
            _=state.handle(.cleaned(id));model.update(state:state,preview:"")
            #expect(model.errorText==message && model.recoveryHelp==help)
            _=state.handle(.toggle(SessionID()));model.update(state:state,preview:"")
            #expect(model.errorText==nil && model.recoveryHelp==nil)
        }
    }

    @Test func lostTargetAfterRecordingOffersRestartAndKeepsCompletionStage() {
        for finishing in [true,false] {
            let model=DictationViewModel(toggle:{});var state=SessionState();let id=SessionID()
            _=state.handle(.toggle(id));_=state.handle(.prepared(id,.init(1)))
            if finishing {_=state.handle(.toggle(SessionID()))}
            _=state.handle(.targetChanged(.init(2),issue:.unavailable));_=state.handle(.cleaned(id))
            model.update(state:state,preview:"")
            #expect(model.errorText=="入力先を確認できなくなったため、音声入力を終了しました")
            #expect(model.recoveryHelp=="入力欄を選び直して、開始キーを押してください")
            #expect(model.panelHeight>=180)
        }
    }

    @Test func targetChangeExplainsWhetherRecordingHadStartedAndClearsOnRetry() {
        for started in [false,true] {
            let model=DictationViewModel(toggle:{});var state=SessionState();let id=SessionID()
            _=state.handle(.toggle(id))
            if started {_=state.handle(.prepared(id,.init(1)))}
            _=state.handle(.targetChanged(.init(2)));model.update(state:state,preview:"")
            #expect(model.title=="終了処理中" && model.errorText==nil)
            _=state.handle(.cleaned(id));model.update(state:state,preview:"")
            #expect(model.errorText == (started
                ? "入力先が変わったため、音声入力を終了しました"
                : "入力先が変わったため、開始を取り消しました"))
            #expect(model.recoveryHelp == (started
                ? "続ける場合は、入力先を選んで開始キーを押してください"
                : "入力したい欄で、開始キーを押してください"))
            _=state.handle(.toggle(SessionID()));model.update(state:state,preview:"")
            #expect(model.errorText==nil && model.title=="準備中")
        }
    }

    @Test func recordingPanelDoesNotRetainTranscriptAndKeepsStatusCompact() {
        let model=DictationViewModel(toggle:{});var state=SessionState();let id=SessionID()
        _=state.handle(.toggle(id));_=state.handle(.prepared(id,.init(1)))
        model.update(state:state,preview:"パネルに表示しない認識本文")
        #expect(model.preview.isEmpty)
        #expect(model.panelHeight==84 && model.panelTitle=="録音中")
        #expect(model.hasRecordingAppearance)
        _=state.handle(.injectionFailed(id));model.update(state:state,preview:"未表示の更新")
        #expect(!model.hasRecordingAppearance && model.panelHeight>=160)
        _=state.handle(.targetChanged(.init(2)));_=state.handle(.cleaned(id));model.update(state:state,preview:"")
        #expect(!model.hasRecordingAppearance && model.panelHeight>=120)
    }

    @Test func suspensionAndFinalizationFailuresRemainVisible() {
        let model=DictationViewModel(toggle:{});var state=SessionState();let id=SessionID()
        _=state.handle(.toggle(id));_=state.handle(.prepared(id,.init(1)));_=state.handle(.injectionFailed(id))
        model.update(state:state,preview:"")
        #expect(model.title=="文字入力保留中")
        #expect(model.suspensionHelp?.contains("開始キーを1回押して終了")==true)
        #expect(model.suspensionHelp?.contains("入力位置を選び直し、もう1回押すと音声入力を再開")==true)
        _=state.handle(.targetChanged(.init(2)));_=state.handle(.cleaned(id));model.update(state:state,preview:"")
        #expect(model.errorText=="入力先が変わったため、音声入力を終了しました")
        #expect(model.suspensionHelp==nil)
        _=state.handle(.cleaned(id));_=state.handle(.toggle(id));_=state.handle(.prepared(id,.init(2)))
        model.update(state:state,preview:"")
        #expect(model.title=="認識中" && model.suspensionHelp==nil && model.errorText==nil)
    }
    @Test func displaysCoordinatorSnapshotsAndCommands() {
        var commands=0
        let model=DictationViewModel(toggle:{commands+=1})
        var state=SessionState();let id=SessionID()
        #expect(model.title == "待機中")
        _=state.handle(.toggle(id));model.update(state:state,preview:"");#expect(model.title == "準備中")
        _=state.handle(.prepared(id,.init(1)));model.update(state:state,preview:"こんにちは");#expect(model.title == "認識中")
        _=state.handle(.toggle(SessionID()));model.update(state:state,preview:"");#expect(model.title == "入力確定中")
        _=state.handle(.timeout(id));model.update(state:state,preview:"");#expect(model.title == "終了処理中" && model.errorText != nil)
        _=state.handle(.cleaned(id));model.update(state:state,preview:"");#expect(model.title == "待機中" && model.errorText != nil)
        model.toggle();#expect(commands == 1)
    }
}
