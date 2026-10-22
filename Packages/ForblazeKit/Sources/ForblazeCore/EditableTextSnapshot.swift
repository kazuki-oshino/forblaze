/// 複数の音声区間を含む編集可能な末尾。音声認識のisFinalとは別の契約。
public struct EditableTextSnapshot:Sendable {
    public let text:String
    public let closesEditing:Bool
    public let isRecognitionFinal:Bool
    public init(text:String,closesEditing:Bool=false,isRecognitionFinal:Bool=false) {
        self.text=text;self.closesEditing=closesEditing;self.isRecognitionFinal=isRecognitionFinal
    }
}
public struct EditableTextPlanner:Sendable {
    public private(set) var issued=""
    public private(set) var closed=false
    public init() {}
    public func plan(_ value:EditableTextSnapshot)->TextEdit? {
        planWithAssessment(value)?.edit
    }
    public func planWithAssessment(_ value:EditableTextSnapshot)->TextEditAssessment? {
        closed ? nil:InjectionPlanner.assessDifference(from:issued,to:value.text)
    }
    public mutating func acknowledge(_ value:EditableTextSnapshot,deleted:Int,inserted:String,completed:Bool) {
        guard let edit=plan(value),deleted>=0,deleted<=edit.deleteCount,edit.insertion.hasPrefix(inserted),
              inserted.isEmpty || deleted==edit.deleteCount else {return}
        issued=String(issued.dropLast(deleted))+inserted
        if completed,issued==value.text,value.closesEditing {closed=true;issued=""}
    }
    public mutating func discardIssuedPrefix(_ prefix:String)->Bool {
        guard !closed,issued.hasPrefix(prefix) else {return false}
        issued=String(issued.dropFirst(prefix.count));return true
    }
}
