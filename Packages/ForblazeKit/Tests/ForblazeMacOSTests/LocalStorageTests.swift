import Foundation
import Testing
import ForblazeApplication
import ForblazeCore
@testable import ForblazeMacOS
struct LocalStorageTests {
    @Test func recoveryDiagnosticsPreserveTypedResultsAndRotateWithoutText() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let log=BoundedDiagnosticLog(directory:root,maximumBytes:2048,generations:2),attempt=UUID()
        let record=FocusRecoveryDiagnostic(attempt:attempt,phase:.after,capability:.unavailable,outcome:.timedOut,
                                           roleQueryStatus:-25205,manual:.unsupported,retries:999,milliseconds:.nan)
        for _ in 0..<30 {try await log.record(record)}
        let files=try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)
        #expect(files.count==2)
        for file in files {
            let data=try Data(contentsOf:file);#expect(data.count<=2048)
            for line in String(decoding:data,as:UTF8.self).split(separator:"\n") {
                let entry=try #require(JSONSerialization.jsonObject(with:Data(line.utf8)) as? [String:Any])
                #expect(Set(entry.keys)==Set(["kind","count","milliseconds","timestamp","recovery"]))
                #expect(entry["kind"] as? String == "focusRecovery")
                let recovery=try #require(entry["recovery"] as? [String:Any])
                #expect(Set(recovery.keys)==Set(["attempt","phase","capability","outcome","roleQueryStatus","manual","retries","milliseconds"]))
                #expect(recovery["attempt"] as? String == attempt.uuidString)
                #expect(recovery["outcome"] as? String == "timedOut" && recovery["capability"] as? String == "unavailable")
                #expect(recovery["roleQueryStatus"] as? Int == -25205 && recovery["retries"] as? Int == 30)
                #expect(recovery["milliseconds"] as? Double == 0)
            }
        }
    }
    @Test func editorPreservesRawTextAndSavedRulesAreLoadedForRecognition() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=FileDictionaryStore(directory:root)
        let initial=try await store.readText()
        #expect(initial.hasPrefix("#"))
        let text="# 自分の用語\n\nクロードコード => Claude Code\n"
        try await store.saveText(text,replacing:initial)
        #expect(try await store.readText()==text)
        let snapshot=try await store.load()
        #expect(TextTransform(dictionary:snapshot).apply(to:"クロードコードを使う")=="Claude Codeを使う")
        let external="# 外部で更新\n誤字 => 正字\n"
        try await store.save(external)
        await #expect(throws:DictionaryFailure.changed) {try await store.saveText("上書き => 禁止",replacing:text)}
        #expect(try await store.readText()==external)
    }

    @Test func editorDoesNotReplaceUnreadableOrMissingExistingFile() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=FileDictionaryStore(directory:root)
        _=try await store.load()
        let file=root.appendingPathComponent("dictionary.txt")
        try Data([0xff,0xfe]).write(to:file)
        await #expect(throws:DictionaryFailure.read) {try await store.readText()}
        await #expect(throws:DictionaryFailure.read) {try await store.saveText("新 => 内容",replacing:"")}
        #expect(try Data(contentsOf:file)==Data([0xff,0xfe]))
        try FileManager.default.removeItem(at:file)
        await #expect(throws:DictionaryFailure.changed) {try await store.saveText("新 => 内容",replacing:"")}
        #expect(!FileManager.default.fileExists(atPath:file.path))
    }

    @Test func dictionaryCreationReloadAndFailuresPreserveFiles() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=FileDictionaryStore(directory:root)
        _=try await store.load()
        let file=root.appendingPathComponent("dictionary.txt")
        #expect(FileManager.default.fileExists(atPath:file.path))
        try await store.save("秘密の規則 => 補正\n不正な行")
        let copy=FileDictionaryStore(directory:root);let result=try await copy.load()
        #expect(result.rules.count==1 && result.issues.count==1)
        let original=try Data(contentsOf:file)
        await #expect(throws:DictionaryFailure.tooLarge) {try await store.save(String(repeating:"x",count:FileDictionaryStore.maximumBytes+1))}
        #expect(try Data(contentsOf:file)==original)
        let invalid=root.appendingPathComponent("not-a-directory")
        try Data([1]).write(to:invalid)
        await #expect(throws:DictionaryFailure.read) {try await FileDictionaryStore(directory:invalid).load()}
        await #expect(throws:DictionaryFailure.write) {try await FileDictionaryStore(directory:invalid).save("x")}
        #expect(try Data(contentsOf:invalid)==Data([1]))
    }
    @Test func diagnosticsContainOnlyTypedFieldsAndStayBounded() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let log=BoundedDiagnosticLog(directory:root,maximumBytes:256,generations:2)
        for _ in 0..<50 {try await log.record(.listening,count:4,milliseconds:250)}
        let files=try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)
        #expect(files.count<=2 && !files.isEmpty)
        for file in files {
            let data=try Data(contentsOf:file);#expect(data.count<=256)
            for line in String(decoding:data,as:UTF8.self).split(separator:"\n") {
                let value=try #require(JSONSerialization.jsonObject(with:Data(line.utf8)) as? [String:Any])
                #expect(Set(value.keys)==Set(["kind","count","milliseconds","timestamp"]))
            }
        }
    }
    @Test func detailedDiagnosticsKeepTypedNumericFieldsAndRotateWithinBounds() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let log=BoundedDiagnosticLog(directory:root,maximumBytes:4096,generations:2),session=UUID()
        let sample=LatencyDiagnostic.Sample(sequence:-1,values:[.total:257,.queue:183,.issue:74,.focus:.nan,.eventPost:-1])
        let details=LatencyDiagnostic(session:session,stage:.input,samples:Array(repeating:sample,count:12))
        for _ in 0..<20 {try await log.record(details)}
        let files=try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)
        #expect(files.count==2)
        for file in files {
            let data=try Data(contentsOf:file);#expect(data.count<=4096)
            for line in String(decoding:data,as:UTF8.self).split(separator:"\n") {
                let value=try #require(JSONSerialization.jsonObject(with:Data(line.utf8)) as? [String:Any])
                #expect(Set(value.keys)==Set(["kind","count","milliseconds","timestamp","details"]))
                let detail=try #require(value["details"] as? [String:Any])
                #expect(detail["session"] as? String == session.uuidString)
                let samples=try #require(detail["samples"] as? [[String:Any]])
                #expect(samples.count==8)
                let fields=try #require(samples.first?["values"] as? [String:Double])
                #expect(fields==["total":257,"queue":183,"issue":74])
            }
        }
    }
}
