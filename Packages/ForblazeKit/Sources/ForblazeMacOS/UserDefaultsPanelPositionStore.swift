import Foundation
import ForblazeApplication
@MainActor public final class UserDefaultsPanelPositionStore:PanelPositionStore {
    public static let key="statusPanel.position.v1"
    private let defaults:UserDefaults
    public init(defaults:UserDefaults) {self.defaults=defaults}
    public func load() -> PanelPosition? {
        guard let data=defaults.data(forKey:Self.key),
              let position=try? JSONDecoder().decode(PanelPosition.self,from:data),position.isValid else {return nil}
        return position
    }
    public func save(_ position:PanelPosition) {
        guard position.isValid,let data=try? JSONEncoder().encode(position) else {return}
        defaults.set(data,forKey:Self.key)
    }
}
