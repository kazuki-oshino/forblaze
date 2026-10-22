import Foundation
import ForblazeApplication
@MainActor public final class UserDefaultsSettingsStore: SettingsStore {
    public static let key = "settings.v1"
    private let defaults: UserDefaults
    public init(defaults:UserDefaults) {self.defaults=defaults}
    private struct Envelope: Codable { let version: Int; let settings: AppSettings }
    private var loadedObject: Any?
    public func load() throws -> StoredSettings {
        loadedObject = defaults.object(forKey: Self.key)
        guard let raw = loadedObject else { return .missing }
        guard let data = raw as? Data,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.version == 1, envelope.settings.isValid else { return .invalid }
        return .valid(envelope.settings)
    }
    public func replace(_ value:StoredSettings) throws {
        switch value {
        case .missing: defaults.removeObject(forKey: Self.key)
        case .invalid:
            guard let loadedObject else { throw SettingsFailure.corrupt }
            defaults.set(loadedObject, forKey: Self.key)
        case .valid(let settings):
            guard settings.isValid else { throw SettingsFailure.invalidCandidate }
            let data = try JSONEncoder().encode(Envelope(version: 1, settings: settings))
            defaults.set(data, forKey: Self.key)
            guard defaults.data(forKey: Self.key) == data else { throw SettingsFailure.save }
        }
    }
}
