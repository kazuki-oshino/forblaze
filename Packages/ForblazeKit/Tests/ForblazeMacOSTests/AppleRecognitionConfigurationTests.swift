import Speech
import Testing
@testable import ForblazeMacOS

@MainActor struct AppleRecognitionConfigurationTests {
    @Test(arguments: [false, true])
    func requestsLiveTextWithoutCandidateInspection(farField: Bool) {
        let preset = ApplePermissionService.preset(farField: farField)
        #expect(preset.reportingOptions == [.volatileResults])
        #expect(preset.attributeOptions == [.audioTimeRange])
        #expect(preset.transcriptionOptions == [.punctuation])
        #expect(preset.contentHints == (farField ? [.farField] : []))
    }
}
