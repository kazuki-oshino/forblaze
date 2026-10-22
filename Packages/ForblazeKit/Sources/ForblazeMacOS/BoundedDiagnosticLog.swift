import Foundation
import ForblazeApplication
public actor BoundedDiagnosticLog: DiagnosticLog {
    private let directory:URL
    private let maximumBytes:Int
    private let generations:Int
    public init() {
        directory=FileManager.default.urls(for:.libraryDirectory,in:.userDomainMask)[0].appendingPathComponent("Logs/forblaze",isDirectory:true)
        maximumBytes=65_536;generations=3
    }
    init(directory:URL,maximumBytes:Int,generations:Int) {self.directory=directory;self.maximumBytes=maximumBytes;self.generations=generations}
    private struct Entry:Encodable {
        let kind:DiagnosticKind
        let count:Int
        let milliseconds:Double
        let timestamp:Double
        var details:LatencyDiagnostic?=nil
        var recovery:FocusRecoveryDiagnostic?=nil
    }
    private func file(_ index:Int) -> URL {directory.appendingPathComponent("diagnostic-\(index).jsonl")}
    public func record(_ kind:DiagnosticKind,count:Int,milliseconds:Double) throws {
        try append(Entry(kind:kind,count:min(max(0,count),1_000_000),milliseconds:milliseconds.isFinite ? min(max(0,milliseconds),86_400_000) : 0,timestamp:Date().timeIntervalSince1970))
    }
    public func record(_ details:LatencyDiagnostic) throws {
        try append(Entry(kind:.latencyDetails,count:details.samples.count,milliseconds:0,timestamp:Date().timeIntervalSince1970,details:details))
    }
    public func record(_ recovery:FocusRecoveryDiagnostic) throws {
        try append(Entry(kind:.focusRecovery,count:recovery.retries,milliseconds:recovery.milliseconds,
                         timestamp:Date().timeIntervalSince1970,recovery:recovery))
    }
    private func append(_ entry:Entry) throws {
        guard maximumBytes>0,generations>0 else {return}
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        guard try directory.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink != true else {throw DictionaryFailure.write}
        var line=try JSONEncoder().encode(entry);line.append(10)
        guard line.count<=maximumBytes else {return}
        func data(_ index:Int) throws -> Data {
            let path=file(index)
            if !FileManager.default.fileExists(atPath:path.path) {return Data()}
            let properties=try path.resourceValues(forKeys:[.isSymbolicLinkKey,.isRegularFileKey,.fileSizeKey])
            guard properties.isSymbolicLink != true,properties.isRegularFile==true,(properties.fileSize ?? 0)<=maximumBytes else {throw DictionaryFailure.read}
            return try Data(contentsOf:path)
        }
        var current=try data(0)
        if current.count+line.count>maximumBytes {
            if generations>1 {
                for index in stride(from:generations-1,through:1,by:-1) {
                    let previous=try data(index-1)
                    // 書き換え先のリンクを追わず、固定名の世代だけを扱う。
                    _=try data(index)
                    try previous.write(to:file(index),options:.atomic)
                }
            }
            current=Data()
        }
        current.append(line);try current.write(to:file(0),options:.atomic)
    }
}
