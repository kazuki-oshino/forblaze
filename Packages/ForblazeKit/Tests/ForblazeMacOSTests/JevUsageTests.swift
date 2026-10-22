import Testing
import Foundation
import ForblazeCore
@testable import ForblazeMacOS

struct JevUsageTests {
    actor MemoryLog:JevUsageRecording {
        var events:[JevUsageEvent]=[]
        func record(_ event:JevUsageEvent) {events.append(event)}
    }
    struct BrokenLog:JevUsageRecording {
        func record(_ event:JevUsageEvent) throws {throw CocoaError(.fileWriteNoPermission)}
    }
    struct CancelledTransport:PunctuationHTTPTransport {
        func send(_ request:URLRequest) async throws -> (Data,Int) {throw URLError(.cancelled)}
    }
    struct CancelAfterResponse:PunctuationHTTPTransport {
        let data:Data
        func send(_ request:URLRequest) async throws -> (Data,Int) {
            withUnsafeCurrentTask {$0?.cancel()}
            return (data,200)
        }
    }
    let fixture=JevPunctuationTests()

    @Test func recordsOneCallForABatchAndActualUsageWithoutAuthorization() async throws {
        let log=MemoryLog()
        var body=try #require(JSONSerialization.jsonObject(with:fixture.response()) as? [String:Any])
        let answers=try #require(body["answers"] as? [String:Any])
        body["answers"]=["p0":answers["p0"]!,"p1":answers["p0"]!]
        let service=JevPunctuationService(configuration:.init(apiKey:"secret-not-in-log"),transport:JevPunctuationTests.StubTransport(data:try JSONSerialization.data(withJSONObject:body),status:200),log:log)
        _=try await service.decide([fixture.candidate,fixture.candidate])
        let events=await log.events
        #expect(events.count==2)
        #expect(events.map(\.apiCalls).reduce(0,+)==1)
        #expect(events[0].requestID==events[1].requestID)
        #expect(events[0].phase == .request && events[1].phase == .response)
        #expect(events[0].questionCount==2)
        #expect(events[0].originalTexts==Array(repeating:"こんにちは。高須クリニックです。",count:2))
        #expect(events[0].requestBody?.contains("こんにちは、高須クリニックです。") == true)
        #expect(events[1].usage?.inputTokens==420 && events[1].usage?.outputTokens==41)
        #expect(events[1].choices == [.comma,.comma] && events[1].outcome == .success)
        let json=String(decoding:try JSONEncoder().encode(events),as:UTF8.self)
        #expect(!json.contains("secret-not-in-log") && !json.contains("Authorization"))
    }
    @Test func retainsUsageEvenWhenAnswerIsRejectedAndMarksMissingUsageUnknown() async throws {
        for (data,status,outcome) in [(fixture.response(choice:"period"),200,JevUsageEvent.Outcome.invalidResponse),(Data("{}".utf8),429,.httpError)] {
            let log=MemoryLog()
            let service=JevPunctuationService(configuration:.init(apiKey:"test"),transport:JevPunctuationTests.StubTransport(data:data,status:status),log:log)
            await #expect(throws:JevFailure.self) {try await service.decide([fixture.candidate])}
            let event=try #require(await log.events.last)
            #expect(event.outcome==outcome && event.httpStatus==status)
            #expect(event.usage?.inputTokens == (status==200 ? 420:nil))
        }
    }
    @Test func cancellationHasACallButUnknownUsageAndLogFailureDoesNotBreakCorrection() async throws {
        let log=MemoryLog()
        let cancelled=JevPunctuationService(configuration:.init(apiKey:"test"),transport:CancelledTransport(),log:log)
        await #expect(throws:URLError.self) {try await cancelled.decide([fixture.candidate])}
        let events=await log.events
        #expect(events.count==2 && events[1].outcome == .cancelled && events[1].usage==nil)
        let service=JevPunctuationService(configuration:.init(apiKey:"test"),transport:JevPunctuationTests.StubTransport(data:fixture.response(),status:200),log:BrokenLog())
        #expect(try await service.decide([fixture.candidate]).first?.choice == .comma)
    }
    @Test func rejectsInvalidTokenCountersWithoutRejectingValidDecisions() async throws {
        for bad in ["-1","true","1.5","\"420\""] {
            let data=Data(String(decoding:fixture.response(),as:UTF8.self).replacingOccurrences(of:"\"input_tokens\":420",with:"\"input_tokens\":\(bad)").utf8)
            let log=MemoryLog()
            let service=JevPunctuationService(configuration:.init(apiKey:"test"),transport:JevPunctuationTests.StubTransport(data:data,status:200),log:log)
            #expect(try await service.decide([fixture.candidate]).first?.choice == .comma)
            #expect(await log.events.last?.usage==nil)
        }
    }
    @Test func invalidRequestDoesNotCountAsAPICall() async {
        let log=MemoryLog()
        let service=JevPunctuationService(configuration:.init(apiKey:"test"),transport:CancelledTransport(),log:log)
        await #expect(throws:JevFailure.self) {try await service.decide([])}
        #expect(await log.events.isEmpty)
    }
    @Test func cancellationAfterResponsePreservesBilledUsage() async throws {
        let log=MemoryLog()
        let service=JevPunctuationService(configuration:.init(apiKey:"test"),transport:CancelAfterResponse(data:fixture.response()),log:log)
        let task=Task {try await service.decide([fixture.candidate])}
        await #expect(throws:CancellationError.self) {try await task.value}
        let event=try #require(await log.events.last)
        #expect(event.outcome == .cancelled && event.usage?.inputTokens==420)
    }
    @Test func diskLogSurvivesReopeningRotatesAndRejectsSymlinks() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let memory=MemoryLog()
        let service=JevPunctuationService(configuration:.init(apiKey:"test"),transport:JevPunctuationTests.StubTransport(data:fixture.response(),status:200),log:memory)
        _=try await service.decide([fixture.candidate])
        let event=try #require(await memory.events.first)
        let size=try JSONEncoder().encode(event).count+1
        let log=JevUsageLog(directory:root,maximumBytes:size+10,generations:2)
        try await log.record(event)
        try await JevUsageLog(directory:root,maximumBytes:size+10,generations:2).record(event)
        try await log.record(event)
        let files=try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)
        #expect(files.count==2)
        for file in files {
            let data=try Data(contentsOf:file)
            #expect(data.count<=size+10)
            #expect(try JSONDecoder().decode(JevUsageEvent.self,from:data).requestID==event.requestID)
            let mode=try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as? Int
            #expect(mode==0o600)
        }
        let target=root.appendingPathComponent("requests-0.jsonl")
        let original=try Data(contentsOf:target)
        let linked=root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at:linked,withDestinationURL:root)
        await #expect(throws:(any Error).self) {try await JevUsageLog(directory:linked).record(event)}
        #expect(try Data(contentsOf:target)==original)
        let outside=root.appendingPathComponent("untouched.txt")
        try Data("do not replace".utf8).write(to:outside)
        let next=root.appendingPathComponent("requests-1.jsonl")
        try FileManager.default.removeItem(at:next)
        try FileManager.default.createSymbolicLink(at:next,withDestinationURL:outside)
        await #expect(throws:(any Error).self) {try await log.record(event)}
        #expect(try String(contentsOf:outside,encoding:.utf8)=="do not replace")
    }
}
