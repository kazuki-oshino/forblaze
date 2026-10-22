import ForblazeCore
public enum DictionaryFailure: Error, Sendable {case read, write, tooLarge, changed}
public protocol DictionaryEditingStore: Sendable {
    func readText() async throws -> String
    func saveText(_ text:String,replacing original:String) async throws
}
public protocol DictionaryStore: Sendable {
    func load() async throws -> DictionarySnapshot
    func save(_ text:String) async throws
}
public enum DiagnosticKind: String, Codable, Sendable {
    case preparing, listening, suspended, finishing, stopping, idle, permissionLost, recognitionFailed, focusChanged, targetUnavailable, targetNoneditable, targetProtected, injectionFailed, audioOverflow, firstResult, audioStopped, finalizationFinished, finalizationTimeout, audioDevice, rawAudioQueuePeak, analyzerInputQueuePeak, recognitionQueuePeak, audioStreams, resultStreams, captureRunning, inputPending
    case firstInputIssued, inputQueueWaitP50, inputQueueWaitP95, inputQueueWaitMax
    case inputIssueDurationP50, inputIssueDurationP95, inputIssueDurationMax
    case recognitionToIssueP50, recognitionToIssueP95, recognitionToIssueMax
    case inputPublications, inputPartialPublications, inputRewrittenCharacters
    case latencyDetails
    case focusRecovery
    case inputLocalizedPublications,inputPreservedCharacters
    case punctuationExpired,punctuationApplied
}
public protocol DiagnosticLog: Sendable {
    func record(_ kind:DiagnosticKind,count:Int,milliseconds:Double) async throws
    func record(_ details:LatencyDiagnostic) async throws
    func record(_ recovery:FocusRecoveryDiagnostic) async throws
}
