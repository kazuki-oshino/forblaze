import Testing
import Foundation
import ForblazeCore
import ForblazeApplication
@testable import ForblazeMacOS

struct JevPunctuationTests {
    struct StubTransport:PunctuationHTTPTransport {
        let data:Data
        let status:Int
        func send(_ request:URLRequest) async throws -> (Data,Int) {(data,status)}
    }
    let candidate=PunctuationCandidate(offset:5,original:.period,left:"こんにちは",right:"高須クリニックです。")
    @Test func encodesTestedCandidatePromptAndModelWithoutCredentialsInBody() throws {
        let config=JevConfiguration(apiKey:"test-secret",model:"jev-1.13.0")
        let request=try JevPunctuationService.makeRequest([candidate],configuration:config)
        #expect(request.url?.absoluteString=="https://api.typesafe.ai/v1/systemone")
        #expect(request.value(forHTTPHeaderField:"Authorization")=="Bearer test-secret")
        #expect(request.timeoutInterval<=2)
        let body=try #require(request.httpBody)
        let json=try #require(JSONSerialization.jsonObject(with:body) as? [String:Any])
        #expect(json["model"] as? String=="jev-1.13.0")
        #expect(!String(decoding:body,as:UTF8.self).contains("test-secret"))
        let questions=try #require(json["questions"] as? [String:[String:Any]])
        let criteria=try #require(questions["p0"]?["criteria"] as? [String:String])
        #expect(criteria==["comma":"こんにちは、高須クリニックです。","period":"こんにちは。高須クリニックです。","none":"こんにちは高須クリニックです。"])
    }
    func response(choice:String="comma",probabilities:String="\"comma\":0.78,\"period\":0.16,\"none\":0.05",model:String="jev-1.13.0")->Data {
        Data("{\"model\":\"\(model)\",\"answers\":{\"p0\":{\"type\":\"choice\",\"choice\":\"\(choice)\",\"confidence\":0.7,\"probabilities\":{\(probabilities)}}},\"usage\":{\"input_tokens\":420,\"output_tokens\":41}}".utf8)
    }
    @Test func validatesRoundedProbabilitiesAndRejectsMismatchedOrMalformedAnswers() throws {
        let values=try JevPunctuationService.decode(response(),candidates:[candidate],model:"jev-1.13.0")
        #expect(values.first?.choice == .comma)
        for invalid in [response(choice:"period"),response(choice:"rewrite"),response(probabilities:"\"comma\":1.1,\"period\":0,\"none\":-0.1"),response(model:"unexpected"),Data("{}".utf8)] {
            #expect(throws:JevFailure.self) {try JevPunctuationService.decode(invalid,candidates:[candidate],model:"jev-1.13.0")}
        }
    }
    @Test func dotenvIsParsedAsDataAndEnvironmentTakesPriority() throws {
        let config=JevConfiguration.resolve(environment:["TYPESAFE_API_KEY":"environment-secret"],fileText:"export TYPESAFE_API_KEY='file-secret'\nFORBLAZE_JEV_MODEL=jev-1.13.0\nOTHER=$(do-not-run)")
        #expect(config?.apiKey=="environment-secret" && config?.model=="jev-1.13.0")
        #expect(JevConfiguration.resolve(environment:[:],fileText:"TYPESAFE_API_KEY=\"file-secret\" # comment")?.apiKey=="file-secret")
        #expect(JevConfiguration.resolve(environment:[:],fileText:"OTHER=none")==nil)
        #expect(JevConfiguration.resolve(environment:["TYPESAFE_API_KEY":""],fileText:"TYPESAFE_API_KEY=old")==nil)
    }
    @Test func transportRejectsHTTPFailuresAndCancellation() async throws {
        for status in [401,429,529,302] {
            let service=JevPunctuationService(configuration:.init(apiKey:"test"),transport:StubTransport(data:response(),status:status))
            await #expect(throws:JevFailure.self) {try await service.decide([candidate])}
        }
        let service=JevPunctuationService(configuration:.init(apiKey:"test"),transport:StubTransport(data:response(),status:200))
        #expect(try await service.decide([candidate]).first?.choice == .comma)
        let task=Task {try await Task.sleep(for:.seconds(10));return try await service.decide([candidate])}
        task.cancel()
        await #expect(throws:CancellationError.self) {try await task.value}
    }
}

/// 明示コマンドのみ有料APIへ接続する。通常のjust testでは実行しない。
struct JevPunctuationLiveTests {
    @Test(.enabled(if:ProcessInfo.processInfo.environment["FORBLAZE_JEV_LIVE_TEST"]=="1"))
    func syntheticExamplesThroughProductionAdapter() async throws {
        var root=URL(fileURLWithPath:#filePath)
        for _ in 0..<5 {root.deleteLastPathComponent()}
        guard let configuration=JevConfiguration.load(developmentFile:root.appendingPathComponent(".env").path) else {
            Issue.record("JevのAPIキーを読み込めません");return
        }
        let examples:[(String,String,PunctuationChoice)]=[("こんにちは","高須クリニックです。",.comma),("確認して","いただけますか。",.none),("料金は1万","2000円です。",.none)]
        let candidates=examples.enumerated().map {PunctuationCandidate(offset:$0.offset,original:.period,left:$0.element.0,right:$0.element.1)}
        let transport=MeasuredJevTransport()
        let logDirectory=root.appendingPathComponent("build/jev-usage-smoke").appendingPathComponent(UUID().uuidString)
        let service=JevPunctuationService(configuration:configuration,transport:transport,log:JevUsageLog(directory:logDirectory))
        let replies=try await service.decide(candidates)
        #expect(replies.map(\.choice)==examples.map(\.2))
        let usage=await transport.usage
        let lines=try String(contentsOf:logDirectory.appendingPathComponent("requests-0.jsonl"),encoding:.utf8).split(separator:"\n")
        let events=try lines.map {try JSONDecoder().decode(JevUsageEvent.self,from:Data($0.utf8))}
        #expect(events.count==2 && events[0].requestID==events[1].requestID)
        #expect(events[1].usage?.inputTokens==usage.0 && events[1].usage?.outputTokens==usage.1)
        #expect(events[1].outcome == .success)
        print("Jev実通信: 1要求・3判定、入力\(usage.0)トークン・出力\(usage.1)トークン")
        print("Jev検証ログ: \(logDirectory.path)")
    }
}
private actor MeasuredJevTransport:PunctuationHTTPTransport {
    private(set) var usage=(0,0)
    func send(_ request:URLRequest) async throws -> (Data,Int) {
        let result=try await JevHTTPTransport().send(request)
        if let json=try? JSONSerialization.jsonObject(with:result.0) as? [String:Any],let tokens=json["usage"] as? [String:Int] {
            usage=(tokens["input_tokens"] ?? 0,tokens["output_tokens"] ?? 0)
        }
        return result
    }
}
