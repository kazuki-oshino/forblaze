import ForblazeCore

public struct PunctuationDecision:Sendable {
    public let candidate:PunctuationCandidate
    public let choice:PunctuationChoice
    public init(candidate:PunctuationCandidate,choice:PunctuationChoice) {self.candidate=candidate;self.choice=choice}
}

/// 通信、モデル名、認証、モデル固有の応答検証は実装側へ閉じ込める。
public protocol PunctuationDecisionService:Sendable {
    func decide(_ candidates:[PunctuationCandidate]) async throws -> [PunctuationDecision]
}
