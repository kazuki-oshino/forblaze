import AppKit
import ForblazeApplication

@MainActor public final class SystemClipboardWriter:ClipboardWriter {
    private let pasteboard:NSPasteboard
    public init(pasteboard:NSPasteboard = .general) {self.pasteboard=pasteboard}
    public func write(_ text:String) {
        pasteboard.clearContents()
        pasteboard.setString(text,forType:.string)
    }
}
