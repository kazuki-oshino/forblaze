import AppKit
@MainActor
final class AppDelegate:NSObject,NSApplicationDelegate {
    private var runtime:AppRuntime?
    func applicationShouldTerminate(_ sender:NSApplication) -> NSApplication.TerminateReply {
        guard let runtime else {return .terminateNow}
        runtime.prepareTermination();return .terminateLater
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        runtime?.openSettings();return true
    }
    func applicationDidFinishLaunching(_ notification:Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        runtime=AppRuntime()
    }
}
let app=NSApplication.shared
let delegate=AppDelegate()
app.delegate=delegate
app.run()
