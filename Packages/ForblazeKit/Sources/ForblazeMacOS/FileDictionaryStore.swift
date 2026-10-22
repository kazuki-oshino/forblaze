import Foundation
import ForblazeCore
import ForblazeApplication
public actor FileDictionaryStore: DictionaryStore, DictionaryEditingStore {
    private let directory:URL
    private let samples:String
    public static let maximumBytes=1_048_576
    public init(samples:String="") {
        directory=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("forblaze",isDirectory:true)
        self.samples=samples
    }
    init(directory:URL,samples:String="") {self.directory=directory;self.samples=samples}
    private var file:URL {directory.appendingPathComponent("dictionary.txt")}
    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        if try directory.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink==true {throw DictionaryFailure.read}
    }
    public func load() throws -> DictionarySnapshot {
        .init(samples:samples,personal:try readText())
    }
    public func readText() throws -> String {try readText(createIfMissing:true)}
    private func readText(createIfMissing:Bool) throws -> String {
        do {
            try ensureDirectory()
            if !FileManager.default.fileExists(atPath:file.path) {
                guard createIfMissing else {throw DictionaryFailure.changed}
                do {try Data("# 誤認識表記 => 正しい表記\n".utf8).write(to:file,options:.withoutOverwriting)}
                catch {guard FileManager.default.fileExists(atPath:file.path) else {throw DictionaryFailure.read}}
            }
            let properties=try file.resourceValues(forKeys:[.isSymbolicLinkKey,.fileSizeKey,.isRegularFileKey])
            guard properties.isSymbolicLink != true,properties.isRegularFile==true else {throw DictionaryFailure.read}
            guard (properties.fileSize ?? 0)<=Self.maximumBytes else {throw DictionaryFailure.tooLarge}
            let data=try Data(contentsOf:file)
            guard data.count<=Self.maximumBytes else {throw DictionaryFailure.tooLarge}
            guard let text=String(data:data,encoding:.utf8) else {throw DictionaryFailure.read}
            return text
        } catch let failure as DictionaryFailure {throw failure}
        catch {throw DictionaryFailure.read}
    }
    public func saveText(_ text:String,replacing original:String) throws {
        guard try readText(createIfMissing:false)==original else {throw DictionaryFailure.changed}
        try save(text)
    }
    public func save(_ text:String) throws {
        let data=Data(text.utf8)
        guard data.count<=Self.maximumBytes else {throw DictionaryFailure.tooLarge}
        do {
            try ensureDirectory()
            if FileManager.default.fileExists(atPath:file.path) {
                let properties=try file.resourceValues(forKeys:[.isSymbolicLinkKey,.isRegularFileKey])
                guard properties.isSymbolicLink != true,properties.isRegularFile==true else {throw DictionaryFailure.write}
            }
            try data.write(to:file,options:.atomic)
        } catch {throw DictionaryFailure.write}
    }
}
