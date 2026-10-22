import Testing
import CoreGraphics
@testable import ForblazeMacOS
struct KeyEventDecoderTests {
    @Test func functionKeyFlagIsNotPhysicalFn() {
        #expect(KeyEventDecoder.modifiers(flags:.maskSecondaryFn,fnPressed:false)==0)
        #expect(KeyEventDecoder.modifiers(flags:.maskSecondaryFn,fnPressed:true)==CGEventFlags.maskSecondaryFn.rawValue)
        #expect(KeyEventDecoder.modifiers(flags:[.maskShift,.maskSecondaryFn],fnPressed:false)==CGEventFlags.maskShift.rawValue)
    }
}
