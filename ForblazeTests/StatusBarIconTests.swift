import AppKit
import Testing
import ForblazeCore

@MainActor struct StatusBarIconTests {
    @Test func recordingFillsTheFlameAndCleanupRestoresTheTemplate() {
        var state=SessionState();let id=SessionID()
        #expect(StatusBarIcon.image(for:state).isTemplate)
        _=state.handle(.toggle(id))
        #expect(StatusBarIcon.image(for:state).isTemplate)
        _=state.handle(.prepared(id,.init(1)))
        #expect(!StatusBarIcon.image(for:state).isTemplate)
        // 入力保留中も収録は続くため、待機の見た目に戻さない。
        _=state.handle(.injectionFailed(id))
        #expect(!StatusBarIcon.image(for:state).isTemplate)
        _=state.handle(.toggle(id));_=state.handle(.cleaned(id))
        #expect(StatusBarIcon.image(for:state).isTemplate)
    }

    @Test func normalStopAndInterruptionRestoreTheOutline() {
        for interrupted in [false,true] {
            var state=SessionState();let id=SessionID()
            _=state.handle(.toggle(id));_=state.handle(.prepared(id,.init(1)))
            _=state.handle(interrupted ? .interrupt(.interrupted):.toggle(id))
            #expect(StatusBarIcon.image(for:state).isTemplate)
            if !interrupted {_=state.handle(.finalized(id))}
            _=state.handle(.cleaned(id))
            #expect(StatusBarIcon.image(for:state).isTemplate)
        }
    }

    @Test func activeShapeIsRecognizableWithoutColorAtBothDisplayScales() throws {
        let idle=StatusBarIcon.image(for:SessionState())
        var state=SessionState();let id=SessionID()
        _=state.handle(.toggle(id));_=state.handle(.prepared(id,.init(1)))
        let active=StatusBarIcon.image(for:state)
        #expect(idle.size==NSSize(width:18,height:18) && active.size==idle.size)
        for scale in [1,2] {
            func bitmap(_ image:NSImage) throws -> NSBitmapImageRep {
                try #require(image.representations.compactMap {$0 as? NSBitmapImageRep}.first {$0.pixelsWide==18*scale})
            }
            let outline=try bitmap(idle),filled=try bitmap(active)
            func coverage(_ rep:NSBitmapImageRep) -> Int {
                (0..<rep.pixelsHigh).reduce(0) {total,y in
                    total+(0..<rep.pixelsWide).filter {rep.colorAt(x:$0,y:y)!.alphaComponent>0}.count
                }
            }
            #expect(coverage(outline)>0)
            #expect(coverage(filled)>coverage(outline)*3/2)
            #expect(filled.colorAt(x:0,y:0)?.alphaComponent==0)
            if scale==2 {
                // Retinaでも各ドットを2×2に保ち、補間でぼかさない。
                for y in stride(from:0,to:36,by:2) {
                    for x in stride(from:0,to:36,by:2) {
                        let color=filled.colorAt(x:x,y:y)
                        #expect(color==filled.colorAt(x:x+1,y:y))
                        #expect(color==filled.colorAt(x:x,y:y+1))
                        #expect(color==filled.colorAt(x:x+1,y:y+1))
                    }
                }
            }
        }
    }
}
