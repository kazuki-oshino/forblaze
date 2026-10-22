import Foundation
import OSLog
import ForblazeCore
import ForblazeApplication

public enum JevFailure:Error,Sendable {case invalidRequest,http(Int),invalidResponse}
public protocol PunctuationHTTPTransport:Sendable {
    func send(_ request:URLRequest) async throws -> (Data,Int)
}
private final class NoJevRedirect:NSObject,URLSessionTaskDelegate {
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping @Sendable (URLRequest?)->Void) {completionHandler(nil)}
}
public struct JevHTTPTransport:PunctuationHTTPTransport {
    private let session:URLSession
    public init() {
        let config=URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest=1.5;config.timeoutIntervalForResource=2
        config.waitsForConnectivity=false;config.urlCache=nil;config.httpCookieStorage=nil
        session=URLSession(configuration:config,delegate:NoJevRedirect(),delegateQueue:nil)
    }
    public func send(_ request:URLRequest) async throws -> (Data,Int) {
        let (data,response)=try await session.data(for:request)
        guard let http=response as? HTTPURLResponse else {throw JevFailure.invalidResponse}
        return (data,http.statusCode)
    }
}

public struct JevPunctuationService:PunctuationDecisionService {
    private let configuration:JevConfiguration
    private let transport:any PunctuationHTTPTransport
    private let log:(any JevUsageRecording)?
    public init(configuration:JevConfiguration,transport:any PunctuationHTTPTransport=JevHTTPTransport(),log:(any JevUsageRecording)?=nil) {
        self.configuration=configuration;self.transport=transport;self.log=log
    }
    public func decide(_ candidates:[PunctuationCandidate]) async throws -> [PunctuationDecision] {
        try Task.checkCancellation()
        let request=try Self.makeRequest(candidates,configuration:configuration)
        let id=UUID().uuidString
        var started=JevUsageEvent(requestID:id,timestamp:Date().timeIntervalSince1970,phase:.request,
                                  model:configuration.model,questionCount:candidates.count,apiCalls:1)
        started.requestBody=request.httpBody.map {String(decoding:$0,as:UTF8.self)}
        started.originalTexts=candidates.map {$0.text(for:$0.original)}
        await record(started)
        let clock=ContinuousClock();let start=clock.now
        var completed=JevUsageEvent(requestID:id,timestamp:started.timestamp,phase:.response,
                                    model:configuration.model,questionCount:candidates.count,apiCalls:0)
        let decisions:[PunctuationDecision]
        do {
            let (data,status)=try await transport.send(request)
            completed.httpStatus=status;completed.usage=JevTokenUsage.read(data)
            // 使用量は取り消し・回答検証より先に確保する。採用しない回答も課金対象になり得る。
            try Task.checkCancellation()
            guard status==200 else {throw JevFailure.http(status)}
            decisions=try Self.decode(data,candidates:candidates,model:configuration.model)
            completed.choices=decisions.map(\.choice);completed.outcome = .success
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {completed.outcome = .cancelled}
            else if case JevFailure.http = error {completed.outcome = .httpError}
            else if error is JevFailure {completed.outcome = .invalidResponse}
            else {completed.outcome = .transportError}
            await finish(completed,start:start,clock:clock)
            throw error
        }
        await finish(completed,start:start,clock:clock)
        try Task.checkCancellation()
        return decisions
    }
    private func finish(_ event:JevUsageEvent,start:ContinuousClock.Instant,clock:ContinuousClock) async {
        var value=event
        value.timestamp=Date().timeIntervalSince1970
        let elapsed=start.duration(to:clock.now).components
        value.elapsedMilliseconds=Double(elapsed.seconds)*1000+Double(elapsed.attoseconds)/1e15
        await record(value)
    }
    private func record(_ event:JevUsageEvent) async {
        do {try await log?.record(event)}
        catch {Logger(subsystem:"dev.kazuki-oshino.forblaze",category:"JevUsage").error("Jev使用量ログの書き込みに失敗しました")}
    }
    public static func makeRequest(_ candidates:[PunctuationCandidate],configuration:JevConfiguration) throws -> URLRequest {
        guard !candidates.isEmpty,candidates.count<=4,
              candidates.allSatisfy({!$0.left.isEmpty && !$0.right.isEmpty && $0.left.count<=64 && $0.right.count<=48}) else {throw JevFailure.invalidRequest}
        func quoted(_ text:String) throws -> String {String(decoding:try JSONEncoder().encode(text),as:UTF8.self)}
        let instructions="Which candidate is the most natural written Japanese? Join greetings and self-introductions with a comma. Separate independent sentences with a period. Do not split words or predicates."
        // 比較評価と同じ comma → period → none の順序をJSON上でも維持する。
        let questions=try candidates.enumerated().map {index,candidate in
            let options=try PunctuationChoice.allCases.map {try quoted($0.rawValue)+":"+quoted(candidate.text(for:$0))}.joined(separator:",")
            return try quoted("p\(index)")+":{\"type\":\"choice\",\"instructions\":"+quoted(instructions)+",\"criteria\":{"+options+"}}"
        }.joined(separator:",")
        let body=try "{\"model\":"+quoted(configuration.model)+",\"state\":"+quoted("句読点だけが異なる三つの候補文を比較してください。")+",\"questions\":{"+questions+"}}"
        var request=URLRequest(url:URL(string:"https://api.typesafe.ai/v1/systemone")!,timeoutInterval:1.5)
        request.httpMethod="POST";request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.setValue("Bearer "+configuration.apiKey,forHTTPHeaderField:"Authorization")
        request.httpBody=Data(body.utf8)
        return request
    }
    public static func decode(_ data:Data,candidates:[PunctuationCandidate],model:String) throws -> [PunctuationDecision] {
        struct Answer:Decodable {let type:String;let choice:PunctuationChoice;let probabilities:[String:Double];let confidence:Double}
        struct Reply:Decodable {let model:String;let answers:[String:Answer]}
        guard data.count<=65_536,let reply=try? JSONDecoder().decode(Reply.self,from:data),reply.model==model,
              Set(reply.answers.keys)==Set(candidates.indices.map {"p\($0)"}) else {throw JevFailure.invalidResponse}
        return try candidates.enumerated().map {index,candidate in
            guard let answer=reply.answers["p\(index)"],answer.type=="choice",
                  answer.confidence.isFinite,(0...1).contains(answer.confidence),
                  Set(answer.probabilities.keys)==Set(PunctuationChoice.allCases.map(\.rawValue)),
                  answer.probabilities.values.allSatisfy({$0.isFinite && (0...1).contains($0)}),
                  abs(answer.probabilities.values.reduce(0,+)-1)<=0.020001,
                  let selected=answer.probabilities[answer.choice.rawValue],selected==answer.probabilities.values.max() else {throw JevFailure.invalidResponse}
            return .init(candidate:candidate,choice:answer.choice)
        }
    }
}
