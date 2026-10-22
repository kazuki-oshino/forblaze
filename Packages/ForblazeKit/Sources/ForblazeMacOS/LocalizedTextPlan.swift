import Foundation
import ForblazeCore
import ForblazeApplication

enum LocalizedReplacementOutcome:Equatable,Sendable {
    case unavailable,applied,stopped(issued:Bool)
}
struct LocalizedReplacementReport:Sendable {
    let outcome:LocalizedReplacementOutcome
    let diagnostic:LocalizedEditDiagnostic
    init(_ outcome:LocalizedReplacementOutcome,diagnostic:LocalizedEditDiagnostic?=nil) {
        self.outcome=outcome
        if let diagnostic {self.diagnostic=diagnostic;return}
        switch outcome {
        case .unavailable:self.diagnostic = .init(stage:.validation,reason:.unsupported,fallbackAllowed:true)
        case .applied:self.diagnostic = .init(stage:.finished,reason:.none,issued:true)
        case .stopped(let issued):self.diagnostic = .init(stage:.validation,reason:.cancelled,issued:issued)
        }
    }
}
@MainActor protocol LocalizedTextReplacing:AnyObject {
    func replace(_ change:LocalizedTextReplacement,context:InjectionContext,
                 permit:@escaping @MainActor ()->Bool,
                 emit:@escaping @MainActor () -> Bool) async -> LocalizedReplacementOutcome
    func replaceReporting(_ change:LocalizedTextReplacement,context:InjectionContext,
                          permit:@escaping @MainActor ()->Bool,
                          emit:@escaping @MainActor () -> Bool) async -> LocalizedReplacementReport
}
extension LocalizedTextReplacing {
    func replaceReporting(_ change:LocalizedTextReplacement,context:InjectionContext,permit:@escaping @MainActor ()->Bool,
                          emit:@escaping @MainActor () -> Bool) async -> LocalizedReplacementReport {
        .init(await replace(change,context:context,permit:permit,emit:emit))
    }
}
struct AccessibleTextState:Equatable,Sendable {
    let value:String
    let selection:NSRange
    let selectedText:String
    /// 照合は正規化による一致ではなくUTF-16の完全一致にする。
    func matches(_ other:Self)->Bool {
        selection==other.selection && value.utf16.elementsEqual(other.value.utf16) && selectedText.utf16.elementsEqual(other.selectedText.utf16)
    }
}
struct LocalizedTextPlan:Sendable {
    static let maximumUTF16=32_768
    let original:AccessibleTextState
    let selected:AccessibleTextState
    let replaced:AccessibleTextState
    let restored:AccessibleTextState
    init?(change:LocalizedTextReplacement,state:AccessibleTextState) {
        let text=state.value as NSString,expected=change.expectedTail as NSString,suffix=change.preservedSuffix as NSString
        guard text.length<=Self.maximumUTF16,state.selection.length==0,state.selectedText.isEmpty,
              state.selection.location>=expected.length,state.selection.location<=text.length,
              expected.length>=suffix.length,suffix.length>0,change.replacement.utf16.count<=16,
              change.expectedTail.utf16.suffix(suffix.length).elementsEqual(change.preservedSuffix.utf16) else {return nil}
        let tailRange=NSRange(location:state.selection.location-expected.length,length:expected.length)
        guard text.substring(with:tailRange).utf16.elementsEqual(change.expectedTail.utf16) else {return nil}
        let selection=NSRange(location:tailRange.location,length:expected.length-suffix.length)
        var boundaries:Set<Int>=[0],offset=0
        for character in state.value {offset += String(character).utf16.count;boundaries.insert(offset)}
        guard boundaries.contains(selection.location),boundaries.contains(NSMaxRange(selection)),boundaries.contains(state.selection.location) else {return nil}
        let oldMiddle=text.substring(with:selection),value=text.replacingCharacters(in:selection,with:change.replacement)
        guard value.utf16.count<=Self.maximumUTF16 else {return nil}
        original=state
        selected = .init(value:state.value,selection:selection,selectedText:oldMiddle)
        replaced = .init(value:value,selection:NSRange(location:selection.location+change.replacement.utf16.count,length:0),selectedText:"")
        restored = .init(value:value,selection:NSRange(location:state.selection.location-selection.length+change.replacement.utf16.count,length:0),selectedText:"")
    }
}
