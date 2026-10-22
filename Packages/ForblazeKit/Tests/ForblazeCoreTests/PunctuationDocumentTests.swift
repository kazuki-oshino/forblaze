import Testing
import ForblazeCore

struct PunctuationDocumentTests {
    @Test func appleChangingOnlyTheTargetMarkDoesNotUndoAcceptedCorrection() throws {
        var document=PunctuationDocument();let id=SegmentID()
        _=document.receive(.init(id:id,range:.init(0,1),text:"確認して。いただけますか。",isFinal:false))
        let candidate=try #require(document.candidates().first)
        document.markAttempted([candidate]);document.accept(.none,for:candidate)
        _=document.receive(.init(id:id,range:.init(0,2),text:"確認して、いただけますか。",isFinal:true))
        #expect(document.rendered=="確認していただけますか。")
        #expect(document.pendingCandidates().isEmpty)
    }
    @Test func dictionaryPunctuationIsProtectedAcrossRecognitionSegments() throws {
        let transform=TextTransform(dictionary:.init(samples:"",personal:"挨拶 => こんにちは、高須クリニックです。"))
        let result=try #require(transform.applyWithProtection(to:"挨拶",maximumCharacters:4096))
        var document=PunctuationDocument()
        _=document.receive(.init(id:SegmentID(),range:.init(0,1),text:result.text,isFinal:true,protectedPunctuation:result.protectedPunctuation))
        _=document.receive(.init(id:SegmentID(),range:.init(1,2),text:"今日は予約の確認です。",isFinal:true))
        #expect(document.pendingCandidates().isEmpty)
        #expect(document.rendered=="こんにちは、高須クリニックです。今日は予約の確認です。")
    }
    @Test func appendedContextCanUsePendingAnswerButRewrittenContextCannot() throws {
        var document=PunctuationDocument();let id=SegmentID()
        _=document.receive(.init(id:id,range:.init(0,1),text:"こんにちは。高須クリニック",isFinal:false))
        let first=try #require(document.candidates().first)
        document.markAttempted([first])
        _=document.receive(.init(id:id,range:.init(0,2),text:"こんにちは。高須クリニックです。",isFinal:true))
        document.accept(.comma,for:first)
        #expect(document.rendered=="こんにちは、高須クリニックです。")
        #expect(document.pendingCandidates().count==1)
    }
    @Test func correctionIsPreservedWhenCompactionStartsAtItsPosition() throws {
        var document=PunctuationDocument()
        let right="高須クリニックです。"
        let first="こんにちは。"+right+String(repeating:"後",count:255-right.count)
        _=document.receive(.init(id:SegmentID(),range:.init(0,1),text:String(repeating:"前",count:600)+first,isFinal:true))
        let candidate=try #require(document.candidates().first)
        document.accept(.comma,for:candidate)
        _=document.receive(.init(id:SegmentID(),range:.init(1,2),text:"続きを話します",isFinal:true))
        let before=document.rendered,count=document.compactableCount
        let prefix=document.renderedPrefix(rawCount:count)
        document.discardPrefix(count)
        #expect(prefix+document.rendered==before)
    }
    @Test func waitsForRightContextAndNeverInventsBoundaries() throws {
        var document=PunctuationDocument()
        let id=SegmentID()
        let received=document.receive(.init(id:id,range:.init(0,1),text:"こんにちは。",isFinal:false))
        #expect(received)
        #expect(document.candidates().isEmpty)
        _=document.receive(.init(id:id,range:.init(0,2),text:"こんにちは。高須クリニックです。",isFinal:true))
        let candidate=try #require(document.candidates().first)
        #expect(document.candidates().count==1)
        #expect(candidate.text(for:.comma)=="こんにちは、高須クリニックです。")
        document.accept(.comma,for:candidate)
        #expect(document.rendered=="こんにちは、高須クリニックです。")
        var plain=PunctuationDocument()
        _=plain.receive(.init(id:id,range:.init(0,1),text:"こんにちは高須クリニックです",isFinal:true))
        #expect(plain.candidates(finalizing:true).isEmpty)
    }

    @Test func recognizesAcrossFinalSegmentsAndRejectsStaleWords() throws {
        var document=PunctuationDocument()
        _=document.receive(.init(id:SegmentID(),range:.init(0,1),text:"こんにちは。",isFinal:true))
        let second=SegmentID()
        _=document.receive(.init(id:second,range:.init(1,2),text:"高須クリニックです。",isFinal:false))
        let old=try #require(document.candidates().first)
        document.accept(.comma,for:old)
        #expect(document.rendered=="こんにちは、高須クリニックです。")
        _=document.receive(.init(id:second,range:.init(1,2),text:"今日は雨が降ります。",isFinal:true))
        document.accept(.none,for:old)
        #expect(document.rendered=="こんにちは。今日は雨が降ります。")
    }

    @Test func deduplicatesAndBoundsRequestsAndContext() throws {
        var document=PunctuationDocument()
        let id=SegmentID()
        _=document.receive(.init(id:id,range:.init(0,1),text:"こんにちは。高須クリニックです。",isFinal:false))
        let first=try #require(document.pendingCandidates().first)
        document.markAttempted([first]);document.accept(.comma,for:first)
        #expect(document.pendingCandidates().isEmpty)
        _=document.receive(.init(id:id,range:.init(0,2),text:"こんにちは。高須クリニックです。よろしくお願いします。",isFinal:true))
        #expect(!document.pendingCandidates().contains(first))
        #expect(document.rendered.hasPrefix("こんにちは、高須"))
        #expect(document.candidates().allSatisfy {$0.left.count<=64 && $0.right.count<=48})
    }

    @Test func removalPreservesEveryOtherCharacterAndCompaction() throws {
        var document=PunctuationDocument()
        _=document.receive(.init(id:SegmentID(),range:.init(0,1),text:String(repeating:"前",count:700)+"東京。スカイツリーです。",isFinal:true))
        _=document.receive(.init(id:SegmentID(),range:.init(1,2),text:"次の文章です。",isFinal:false))
        let candidate=try #require(document.candidates().first)
        document.accept(.none,for:candidate)
        let before=document.rendered, count=document.compactableCount
        #expect(count>0)
        let prefix=document.renderedPrefix(rawCount:count)
        document.discardPrefix(count)
        #expect(prefix+document.rendered==before)
        #expect(document.raw.count<=512)
    }
}
