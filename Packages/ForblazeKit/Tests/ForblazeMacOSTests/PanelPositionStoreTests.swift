import Foundation
import Testing
import ForblazeApplication
import ForblazeMacOS
@MainActor struct PanelPositionStoreTests {
    @Test func restoresPositionWithoutChangingDictationSettings() throws {
        let name="forblaze.tests."+UUID().uuidString
        let defaults=UserDefaults(suiteName:name)!
        defer {defaults.removePersistentDomain(forName:name)}
        let settings=UserDefaultsSettingsStore(defaults:defaults)
        try settings.replace(.valid(.init(sounds:false)))
        let original=defaults.data(forKey:UserDefaultsSettingsStore.key)
        let store=UserDefaultsPanelPositionStore(defaults:defaults)
        #expect(store.load()==nil)
        let position=PanelPosition(x:-850.5,y:1200.25)
        store.save(position)
        #expect(UserDefaultsPanelPositionStore(defaults:UserDefaults(suiteName:name)!).load()==position)
        #expect(defaults.data(forKey:UserDefaultsSettingsStore.key)==original)
        store.save(.init(x:.infinity,y:0))
        #expect(store.load()==position)
    }
    @Test func invalidStoredCoordinatesUseTheDefaultPlacement() {
        let name="forblaze.tests."+UUID().uuidString
        let defaults=UserDefaults(suiteName:name)!
        defer {defaults.removePersistentDomain(forName:name)}
        let store=UserDefaultsPanelPositionStore(defaults:defaults)
        for value:Any in ["broken",Data("{}".utf8),Data("{\"x\":1e999,\"y\":0}".utf8)] {
            defaults.set(value,forKey:UserDefaultsPanelPositionStore.key)
            #expect(store.load()==nil)
        }
    }
}
