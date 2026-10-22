import Foundation
import ForblazeCore

public struct JevTokenUsage:Codable,Sendable,Equatable {
    public let inputTokens:Int
    public let outputTokens:Int
    static func read(_ data:Data)->Self? {
        struct WireUsage:Decodable {let input_tokens:Int;let output_tokens:Int}
        struct Reply:Decodable {let usage:WireUsage}
        guard data.count<=65_536,let reply=try? JSONDecoder().decode(Reply.self,from:data),
              reply.usage.input_tokens>=0,reply.usage.output_tokens>=0 else {return nil}
        return .init(inputTokens:reply.usage.input_tokens,outputTokens:reply.usage.output_tokens)
    }
}

/// requestとresponseをIDで結ぶ。APIキー・HTTPヘッダー・自由形式のエラーは受け取らない。
public struct JevUsageEvent:Codable,Sendable {
    public enum Phase:String,Codable,Sendable {case request,response}
    public enum Outcome:String,Codable,Sendable {case success,httpError,invalidResponse,cancelled,transportError}
    public var schemaVersion=1
    public let requestID:String
    public var timestamp:Double
    public let phase:Phase
    public let model:String
    public let questionCount:Int
    public let apiCalls:Int
    public var requestBody:String?
    public var originalTexts:[String]?
    public var usage:JevTokenUsage?
    public var choices:[PunctuationChoice]?
    public var httpStatus:Int?
    public var outcome:Outcome?
    public var elapsedMilliseconds:Double?
}

public protocol JevUsageRecording:Sendable {
    func record(_ event:JevUsageEvent) async throws
}

/// 本文を含むローカル計測。1MiB×10世代だけを保持し、専用ファイルへ追記する。
public actor JevUsageLog:JevUsageRecording {
    private let directory:URL
    private let maximumBytes:Int
    private let generations:Int
    public init() {
        directory=FileManager.default.urls(for:.libraryDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("Logs/forblaze/jev",isDirectory:true)
        maximumBytes=1_048_576;generations=10
    }
    init(directory:URL,maximumBytes:Int=1_048_576,generations:Int=10) {
        self.directory=directory;self.maximumBytes=maximumBytes;self.generations=generations
    }
    private func file(_ index:Int)->URL {directory.appendingPathComponent("requests-\(index).jsonl")}
    private func attributes(_ url:URL) throws -> [FileAttributeKey:Any]? {
        do {
            let values=try FileManager.default.attributesOfItem(atPath:url.path)
            guard values[.type] as? FileAttributeType == .typeRegular else {throw CocoaError(.fileWriteInvalidFileName)}
            return values
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {return nil}
    }
    public func record(_ event:JevUsageEvent) throws {
        guard maximumBytes>0,generations>0 else {throw CocoaError(.fileWriteUnknown)}
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
        var line=try encoder.encode(event);line.append(10)
        guard line.count<=maximumBytes else {throw CocoaError(.fileWriteOutOfSpace)}
        let manager=FileManager.default
        try manager.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let directoryAttributes=try manager.attributesOfItem(atPath:directory.path)
        guard directoryAttributes[.type] as? FileAttributeType == .typeDirectory else {throw CocoaError(.fileWriteInvalidFileName)}
        try manager.setAttributes([.posixPermissions:0o700],ofItemAtPath:directory.path)
        // ローテーション前に全ての固定名を検査し、リンクや他種のファイルを移動しない。
        let existing=try (0..<generations).map {try attributes(file($0))}
        guard existing.allSatisfy({(($0?[.size] as? NSNumber)?.intValue ?? 0)<=maximumBytes}) else {throw CocoaError(.fileReadTooLarge)}
        let size=(existing[0]?[.size] as? NSNumber)?.intValue ?? 0
        if size+line.count>maximumBytes {
            if existing[generations-1] != nil {try manager.removeItem(at:file(generations-1))}
            if generations>1 {
                for index in stride(from:generations-1,through:1,by:-1) where existing[index-1] != nil {
                    try manager.moveItem(at:file(index-1),to:file(index))
                }
            }
        }
        // O_NOFOLLOWは検査後の置換でもリンク先へ書き込ませない。本文は所有者だけが読める。
        let descriptor=open(file(0).path,O_WRONLY|O_CREAT|O_APPEND|O_NOFOLLOW,0o600)
        guard descriptor>=0 else {throw CocoaError(.fileWriteUnknown)}
        let handle=FileHandle(fileDescriptor:descriptor,closeOnDealloc:true)
        defer {try? handle.close()}
        guard fchmod(descriptor,0o600)==0 else {throw CocoaError(.fileWriteNoPermission)}
        try handle.write(contentsOf:line)
    }
}
