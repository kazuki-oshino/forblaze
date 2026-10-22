import Testing
import ForblazeTestSupport
@testable import ForblazeApplication

@MainActor struct SpeechPreparationTests {
    @Test func onlyAReadyMatchingResourceIsConsumedAndNeverReleasedTwice() async {
        var released:[Int]=[]
        let slot=SpeechPreparationController<Bool,Int>(release:{released.append($0)})
        slot.request(key:true,prepare:{7})
        await slot.waitForPreparation()
        #expect(slot.take(key:true)==7)
        await slot.close()
        #expect(released.isEmpty && slot.take(key:true)==nil)
    }
    @Test func keyChangeCancelsStalePreparationAndSerializesTheNextOne() async {
        var released:[Int]=[],started:[Int]=[]
        let gate=ControlledGate<Bool>(),entered=ControlledGate<Bool>()
        let slot=SpeechPreparationController<Int,Int>(release:{released.append($0)})
        slot.request(key:1,prepare:{started.append(1);await entered.send(true);_=await gate.next();return 1})
        _=await entered.next()
        slot.request(key:2,prepare:{started.append(2);return 2})
        #expect(started==[1])
        await gate.send(true);await slot.waitForPreparation()
        #expect(started==[1,2] && released==[1])
        #expect(slot.take(key:2)==2)
        await slot.close();#expect(released==[1])
    }
    @Test func startingBeforePreparationFinishesDoesNotWaitOrReuseLateCompletion() async {
        var released:[Int]=[]
        let gate=ControlledGate<Bool>(),entered=ControlledGate<Bool>()
        let slot=SpeechPreparationController<Int,Int>(release:{released.append($0)})
        slot.request(key:1,prepare:{await entered.send(true);_=await gate.next();return 1})
        _=await entered.next()
        #expect(slot.take(key:1)==nil)
        await gate.send(true);await slot.close()
        #expect(released==[1] && slot.take(key:1)==nil)
    }
}
