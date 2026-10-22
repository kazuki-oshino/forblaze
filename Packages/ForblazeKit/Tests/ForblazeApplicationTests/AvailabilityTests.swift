import Testing
import ForblazeApplication
struct AvailabilityTests {
    @Test func independentStatesAndModelPreparation() {
        let granted=Dictionary(uniqueKeysWithValues:PermissionKind.allCases.map{($0,PermissionStatus.granted)})
        #expect(!Availability().canStart)
        for kind in PermissionKind.allCases {
            for status in [PermissionStatus.unknown,.denied,.restricted] {
                var permissions=granted;permissions[kind]=status
                let a=Availability(permissions:permissions,model:.installed,eventTap:.available)
                #expect(!a.canStart && a.blockers.contains(kind.rawValue))
            }
        }
        #expect(Availability(permissions:granted,model:.missing,eventTap:.available).canStart)
        #expect(!Availability(permissions:granted,model:.unsupported,eventTap:.available).canStart)
        #expect(!Availability(permissions:granted,model:.installed,eventTap:.failed).canStart)
    }
}
