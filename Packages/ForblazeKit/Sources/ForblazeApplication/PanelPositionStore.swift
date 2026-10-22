/// AppKitの画面座標で表したパネル左下の位置。音声入力の設定とは独立して保存する。
public struct PanelPosition: Codable, Equatable, Sendable {
    public let x:Double
    public let y:Double
    public init(x:Double,y:Double) {self.x=x;self.y=y}
    public var isValid:Bool {x.isFinite && y.isFinite}
}
@MainActor public protocol PanelPositionStore {
    func load() -> PanelPosition?
    func save(_ position:PanelPosition)
}
