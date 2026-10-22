import AppKit
import Testing
import ForblazeMacOS

@MainActor struct ClipboardWriterTests {
    @Test func replacesOnlyTheSuppliedPasteboardWithPlainText() {
        let pasteboard=NSPasteboard.withUniqueName()
        defer {pasteboard.releaseGlobally()}
        pasteboard.setString("前の内容",forType:.string)
        pasteboard.setData(Data([1,2,3]),forType:.png)
        SystemClipboardWriter(pasteboard:pasteboard).write("コピーする全文👨‍👩‍👧。\n次の行")
        #expect(pasteboard.string(forType:.string) == "コピーする全文👨‍👩‍👧。\n次の行")
        #expect(pasteboard.data(forType:.png)==nil)
    }
}
