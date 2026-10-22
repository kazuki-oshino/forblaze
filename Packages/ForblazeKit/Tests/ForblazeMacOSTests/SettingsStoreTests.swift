import Testing
import Foundation
import ForblazeApplication
import ForblazeCore
import ForblazeMacOS
@MainActor struct SettingsStoreTests {
    @Test func outputSilencingIsOptInAndSurvivesReload() throws {
        let old=Data("{\"binding\":{\"version\":1,\"keyCode\":101,\"modifiers\":0},\"farField\":true,\"sounds\":true}".utf8)
        var migrated=try JSONDecoder().decode(AppSettings.self,from:old)
        #expect(!AppSettings().muteOutputDuringDictation && !migrated.muteOutputDuringDictation && migrated.sounds)
        let name="forblaze.tests."+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        defer {defaults.removePersistentDomain(forName:name)}
        for enabled in [true,false] {
            migrated.muteOutputDuringDictation=enabled
            try UserDefaultsSettingsStore(defaults:defaults).replace(.valid(migrated))
            #expect(try UserDefaultsSettingsStore(defaults:defaults).load() == .valid(migrated))
        }
    }
    @Test func performanceOptionsMigrateWithoutChangingExistingBehavior() throws {
        let old=Data("{\"binding\":{\"version\":1,\"keyCode\":101,\"modifiers\":0},\"farField\":true,\"sounds\":true}".utf8)
        var migrated=try JSONDecoder().decode(AppSettings.self,from:old)
        #expect(!migrated.prewarmRecognition && !migrated.balancedInput && migrated.speechBufferSize == .standard)
        for size in SpeechBufferSize.allCases {
            migrated.speechBufferSize=size;migrated.prewarmRecognition=true;migrated.balancedInput=true
            let encoded=try JSONEncoder().encode(migrated)
            #expect(try JSONDecoder().decode(AppSettings.self,from:encoded)==migrated)
        }
    }
    @Test func clipboardIsOptInForOldSettingsAndSurvivesReload() throws {
        let old=Data("{\"binding\":{\"version\":1,\"keyCode\":101,\"modifiers\":0},\"farField\":false,\"sounds\":true,\"forblazeMode\":true}".utf8)
        var migrated=try JSONDecoder().decode(AppSettings.self,from:old)
        #expect(!migrated.copyToClipboard && migrated.forblazeMode && !migrated.farField)
        #expect(!AppSettings().copyToClipboard)
        let name="forblaze.tests."+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        defer {defaults.removePersistentDomain(forName:name)}
        for enabled in [true,false] {
            migrated.copyToClipboard=enabled
            try UserDefaultsSettingsStore(defaults:defaults).replace(.valid(migrated))
            #expect(try UserDefaultsSettingsStore(defaults:defaults).load() == .valid(migrated))
        }
    }
    @Test func blazeMigrationPreservesExistingSettingsAndPersistsTheOptIn() throws {
        let old=Data("{\"binding\":{\"version\":1,\"keyCode\":101,\"modifiers\":0},\"farField\":false,\"sounds\":false,\"punctuationCorrection\":true}".utf8)
        let migrated=try JSONDecoder().decode(AppSettings.self,from:old)
        #expect(!migrated.forblazeMode && migrated.punctuationCorrection && !migrated.farField && !migrated.sounds)
        #expect(migrated.binding.keyCode == 101)
        let name="forblaze.tests."+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        defer {defaults.removePersistentDomain(forName:name)}
        var expected=migrated;expected.forblazeMode=true
        try UserDefaultsSettingsStore(defaults:defaults).replace(.valid(expected))
        #expect(try UserDefaultsSettingsStore(defaults:defaults).load() == .valid(expected))
    }
    @Test func oldSettingsDefaultCorrectionOffAndNewSettingSurvivesReload() throws {
        let old=Data("{\"binding\":{\"version\":1,\"keyCode\":101,\"modifiers\":0},\"farField\":false,\"sounds\":true}".utf8)
        let migrated=try JSONDecoder().decode(AppSettings.self,from:old)
        #expect(!migrated.punctuationCorrection && !migrated.farField)
        let name="forblaze.tests."+UUID().uuidString
        let defaults=UserDefaults(suiteName:name)!
        defer {defaults.removePersistentDomain(forName:name)}
        let expected=AppSettings(punctuationCorrection:true)
        try UserDefaultsSettingsStore(defaults:defaults).replace(.valid(expected))
        #expect(try UserDefaultsSettingsStore(defaults:defaults).load() == .valid(expected))
    }
    @Test func isolatedPersistenceAndCorruption() throws {
        let name="forblaze.tests."+UUID().uuidString
        let defaults=UserDefaults(suiteName:name)!
        defer {defaults.removePersistentDomain(forName:name)}
        let store=UserDefaultsSettingsStore(defaults:defaults)
        #expect(try store.load() == .missing)
        let expected=AppSettings(binding:.init(keyCode:101),farField:false,sounds:false)
        try store.replace(.valid(expected))
        #expect(try UserDefaultsSettingsStore(defaults:defaults).load() == .valid(expected))
        let cases:[Any]=["broken",Data([255]),Data("{\"version\":99,\"settings\":{}}".utf8),Data("{\"version\":1,\"settings\":{\"binding\":{\"version\":1,\"keyCode\":36,\"modifiers\":0},\"farField\":true,\"sounds\":true}}".utf8)]
        for raw in cases {
            defaults.set(raw,forKey:UserDefaultsSettingsStore.key)
            #expect(try store.load() == .invalid)
            #expect(defaults.object(forKey:UserDefaultsSettingsStore.key) != nil)
        }
    }
}
