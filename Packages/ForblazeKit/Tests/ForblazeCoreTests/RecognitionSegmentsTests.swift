import Testing
@testable import ForblazeCore
struct RecognitionSegmentsTests {
    @Test func observedZeroDurationFinalAtSealedBoundaryDoesNotBreakNextPhrase() {
        // f5e3a63c968f2de8実機観測。本文は使用しない。
        let session=SessionID();var mapper=RecognitionSegments(session:session)
        let groups:[([Double],Double,Double)]=[
            ([1.2,1.68,1.68,1.92,2.16,2.4,2.64,3.12,3.12,3.36,3.6,3.84,3.84],0.42,5.52),
            ([6,6.24,7.2,7.44,7.92,8.16,9.12,9.72,9.84,10.56,10.8,10.8],5.52,12.48),
            ([15.84,16.56,18,18.12,18.24,18.24,18.72,19.14,19.2,19.2,19.2,19.44,19.44,19.56,19.92,19.92],14.73,21.6)
        ]
        var last:SegmentResolution?
        for (ends,finalStart,finalEnd) in groups {
            let start=mapper.finalizedEnd
            let first=mapper.resolve(session:session,range:.init(start,ends[0]),isFinal:false)
            if case .update = first {} else {Issue.record("途中結果の更新が必要")}
            for end in ends.dropFirst() {#expect(mapper.resolve(session:session,range:.init(start,end),isFinal:false)==first)}
            #expect(mapper.resolve(session:session,range:.init(finalStart,finalEnd),isFinal:true)==first)
            last=first
        }
        #expect(mapper.resolve(session:session,range:.init(21.6,21.6),isFinal:true) == .duplicate)
        #expect(mapper.finalizedEnd==21.6)
        let next=mapper.resolve(session:session,range:.init(21.6,22.2),isFinal:false)
        if case .update = next {#expect(next != last)} else {Issue.record("境界通知の後も次の発話を開始できること")}
        // 遅れて再通知されても、現在の未確定区間を消さない。
        #expect(mapper.resolve(session:session,range:.init(21.6,21.6),isFinal:true) == .duplicate)
        #expect(mapper.resolve(session:session,range:.init(21.7,22.5),isFinal:true)==next)
        #expect(mapper.finalizedEnd==22.5)
    }
    @Test func boundaryFinalDoesNotRelaxInvalidRangeChecks() {
        let session=SessionID();var mapper=RecognitionSegments(session:session)
        _=mapper.resolve(session:session,range:.init(0,1),isFinal:true)
        for range:AudioRange in [.init(1,0.9),.init(-1,-1),.init(.nan,1),.init(1,.infinity),.init(2,2)] {
            #expect(mapper.resolve(session:session,range:range,isFinal:true) == .invalid)
        }
        #expect(mapper.resolve(session:SessionID(),range:.init(1,1),isFinal:true) == .invalid)
        #expect(mapper.resolve(session:session,range:.init(1,1),isFinal:false) == .invalid)
        #expect(mapper.finalizedEnd==1)
    }
    @Test func observedFinalSpeechOnsetMovesInsideVolatileRange() {
        // ead8fc88c41e5b21実機観測。本文は使用せず時間範囲だけを再現する。
        let session=SessionID();var mapper=RecognitionSegments(session:session)
        let first=mapper.resolve(session:session,range:.init(0,0.96),isFinal:false)
        #expect(mapper.resolve(session:session,range:.init(0,1.2),isFinal:false)==first)
        let final=mapper.resolve(session:session,range:.init(0.48,1.94225),isFinal:true)
        #expect(final==first && mapper.finalizedEnd==1.94225)
        #expect(mapper.resolve(session:session,range:.init(0.48,1.94225),isFinal:true) == .duplicate)
        let next=mapper.resolve(session:session,range:.init(1.94225,2.5),isFinal:false)
        if case .update = next {#expect(next != first)} else {Issue.record("次の発話を開始できない")}
        #expect(mapper.resolve(session:session,range:.init(2.1,2.8),isFinal:true)==next)
        #expect(mapper.finalizedEnd==2.8)
    }
    @Test func shiftedFinalCannotRewriteSealedOrSkipUnfinalizedRange() {
        let session=SessionID();var mapper=RecognitionSegments(session:session)
        _=mapper.resolve(session:session,range:.init(0,1),isFinal:true)
        _=mapper.resolve(session:session,range:.init(1,2),isFinal:false)
        #expect(mapper.resolve(session:session,range:.init(0.8,2.2),isFinal:true) == .invalid)
        #expect(mapper.resolve(session:session,range:.init(2.1,3),isFinal:true) == .invalid)
        #expect(mapper.finalizedEnd==1)
    }

    @Test func observedMicrophoneMetadataKeepsOneSegment() {
        // b4f8466相当の実ビルド、Amazon USB Streaming Mic。本文は収集しない。
        let ends:[Double]=[1.2,1.32,1.68,1.92,1.92,2.1,2.16,2.4,2.4,2.64,2.64,2.88,3.12,3.36,3.6,3.6,3.6,3.84,3.84,4.08,4.32,4.6394375,4.6394375]
        let session=SessionID();var mapper=RecognitionSegments(session:session)
        var previous:SegmentResolution?
        for end in ends {
            let result=mapper.resolve(session:session,range:.init(0,end),isFinal:false)
            if let previous {#expect(result==previous)}
            if case .update = result {} else {Issue.record("実時間範囲が拒否された")}
            previous=result
        }
    }
    @Test func correctionSplitAndDuplicateUseTimeNotText() {
        let session=SessionID();var segments=RecognitionSegments(session:session)
        let a=segments.resolve(session:session,range:.init(0,2),isFinal:false)
        let revised=segments.resolve(session:session,range:.init(0,3),isFinal:false)
        #expect(a==revised);if case .update = a {} else {Issue.record("更新が必要")}
        let firstFinal=segments.resolve(session:session,range:.init(0,1),isFinal:true)
        #expect(firstFinal==a)
        let duplicate=segments.resolve(session:session,range:.init(0,1),isFinal:true)
        #expect(duplicate == .duplicate)
        let second=segments.resolve(session:session,range:.init(1,3),isFinal:true)
        #expect(second != firstFinal);if case .update = second {} else {Issue.record("別区間が必要")}
        #expect(segments.finalizedEnd==3)
    }
    @Test func ambiguousMergeAndOldSessionAreRejected() {
        let session=SessionID();var segments=RecognitionSegments(session:session)
        _=segments.resolve(session:session,range:.init(0,1),isFinal:true)
        let merge=segments.resolve(session:session,range:.init(0,2),isFinal:false)
        #expect(merge == .invalid)
        let old=segments.resolve(session:SessionID(),range:.init(1,2),isFinal:false)
        #expect(old == .invalid)
        let nan=segments.resolve(session:session,range:.init(.nan,2),isFinal:false)
        #expect(nan == .invalid)
        _=segments.resolve(session:session,range:.init(1,3),isFinal:false)
        let overlap=segments.resolve(session:session,range:.init(2,4),isFinal:false)
        #expect(overlap == .invalid)
    }
}
