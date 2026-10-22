import Foundation

public struct JevConfiguration:Sendable {
    public let apiKey:String
    public let model:String
    public init(apiKey:String,model:String="jev-1.13.0") {self.apiKey=apiKey;self.model=model}
    public static func resolve(environment:[String:String],fileText:String?)->Self? {
        var values:[String:String]=[:]
        for line in (fileText ?? "").split(whereSeparator:\.isNewline) {
            var text=line.trimmingCharacters(in:.whitespaces)
            if text.hasPrefix("export ") {text=String(text.dropFirst(7)).trimmingCharacters(in:.whitespaces)}
            guard !text.hasPrefix("#"),let separator=text.firstIndex(of:"=") else {continue}
            let key=text[..<separator].trimmingCharacters(in:.whitespaces)
            guard ["TYPESAFE_API_KEY","FORBLAZE_JEV_MODEL"].contains(key) else {continue}
            var value=text[text.index(after:separator)...].trimmingCharacters(in:.whitespaces)
            if let quote=value.first,quote=="\"" || quote=="'" {
                guard let end=value.dropFirst().firstIndex(of:quote) else {continue}
                value=String(value[value.index(after:value.startIndex)..<end])
            } else if let comment=value.range(of:" #") {value=String(value[..<comment.lowerBound])}
            values[key]=value.trimmingCharacters(in:.whitespaces)
        }
        for key in ["TYPESAFE_API_KEY","FORBLAZE_JEV_MODEL"] {if let value=environment[key] {values[key]=value}}
        guard let key=values["TYPESAFE_API_KEY"],!key.isEmpty,
              !key.contains(where:{$0.isNewline || $0.isWhitespace}) else {return nil}
        let model=values["FORBLAZE_JEV_MODEL"] ?? "jev-1.13.0"
        guard !model.isEmpty,model.count<=100,!model.contains(where:\.isWhitespace) else {return nil}
        return Self(apiKey:key,model:model)
    }
    /// .envはシェルとして実行しない。キーをバンドルやUserDefaultsへコピーしない。
    public static func load(environment:[String:String]=ProcessInfo.processInfo.environment,developmentFile:String?=nil)->Self? {
        let files:[URL]
        if let path=environment["FORBLAZE_ENV_FILE"] {files=[URL(fileURLWithPath:path)]}
        else {
            let support=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/forblaze/.env")
            files=[support]+(developmentFile.map {[URL(fileURLWithPath:$0)]} ?? [])
        }
        let text=files.first(where:{FileManager.default.fileExists(atPath:$0.path)}).flatMap {url -> String? in
            guard let size=try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize,size<=65_536 else {return nil}
            return try? String(contentsOf:url,encoding:.utf8)
        }
        return resolve(environment:environment,fileText:text)
    }
}
