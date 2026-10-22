import Testing
@testable import ForblazeCore
struct FocusTests {
    @Test func capabilitiesAndStaleReplies() {
        let a=FocusTarget(id:.init(process:1,element:1),capability:.editable)
        let b=FocusTarget(id:.init(process:1,element:2),capability:.editable)
        #expect(a.permitsInput)
        for capability in [TargetCapability.noneditable,.protected,.unavailable] {
            #expect(!FocusTarget(id:a.id,capability:capability).permitsInput)
        }
        var g=FocusGeneration();let old=g.begin(),new=g.begin()
        let accepted=g.accept(b,request:new);#expect(accepted);let epoch=g.epoch
        let stale=g.accept(a,request:old);#expect(!stale);#expect(g.target==b && g.epoch==epoch)
        let next=g.begin();let changed=g.accept(a,request:next);#expect(changed);#expect(g.epoch != epoch)
        g.invalidate();let invalid=g.accept(a,request:new);#expect(g.target==nil && !invalid)
    }
}
