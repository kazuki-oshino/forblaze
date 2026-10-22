import Foundation
import Testing
@testable import ForblazeMacOS

@MainActor struct ApplePermissionServiceTests {
    @Test(arguments: [false, true])
    func opensInputMonitoringSettingsAfterRequest(granted: Bool) async {
        var actions=[String]()
        let service=ApplePermissionService(inputMonitoringAccess: {false},
            requestInputMonitoringAccess: {actions.append("request");return granted},
            openSettings: {actions.append($0.absoluteString);return true})

        let result=await service.request(.inputMonitoring)

        #expect(result == granted)
        #expect(actions == ["request","x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ListenEvent"])
    }

    @Test func opensSettingsWithoutRequestingGrantedAccessAgain() async {
        var requests=0
        var opened=[URL]()
        let service=ApplePermissionService(inputMonitoringAccess: {true},
            requestInputMonitoringAccess: {requests+=1;return false},
            openSettings: {opened.append($0);return true})

        let result=await service.request(.inputMonitoring)

        #expect(result)
        #expect(requests == 0)
        #expect(opened.map(\.absoluteString) == ["x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ListenEvent"])
    }
}
