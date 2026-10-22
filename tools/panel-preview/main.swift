import AppKit
import SwiftUI
import ForblazeCore

/// 実サービスを起動せず、本番のViewを固定した状態で描画する。
@main struct PanelPreview {
    @MainActor static func main() throws {
        let directory=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let targetCases:[String:(TargetIssue,Bool)]=[
            "target-unavailable":(.unavailable,false),"target-noneditable":(.noneditable,false),
            "target-protected":(.protected,false),"start-canceled":(.changed,false),
            "target-lost":(.unavailable,true),"target-became-noneditable":(.noneditable,true),
            "target-became-protected":(.protected,true)
        ]
        for name in ["recording","silence","preparing","error","suspended","target-stopping"]+targetCases.keys.sorted() {
            let model=DictationViewModel(toggle:{});var state=SessionState();let id=SessionID()
            _=state.handle(.toggle(id))
            if name != "preparing",targetCases[name]?.1 != false {_=state.handle(.prepared(id,.init(1)))}
            if name=="error" {_=state.handle(.targetChanged(.init(2)));_=state.handle(.cleaned(id))}
            if name=="target-stopping" {_=state.handle(.targetChanged(.init(2),issue:.unavailable))}
            if let (issue,_)=targetCases[name] {_=state.handle(.failed(id,.target(issue)));_=state.handle(.cleaned(id))}
            if name=="suspended" {_=state.handle(.injectionFailed(id))}
            model.update(state:state,preview:"表示しないテスト本文")
            model.level=name=="recording" ? 0.04:0
            if name=="preparing" {model.modelProgress=0.45}
            let renderer=ImageRenderer(content:StatusPanelView(model:model,animationEnabled:false).padding(16).background(Color(white:0.12)))
            renderer.scale=2
            guard let image=renderer.nsImage,let tiff=image.tiffRepresentation,
                  let bitmap=NSBitmapImageRep(data:tiff),let png=bitmap.representation(using:.png,properties:[:]) else {throw CocoaError(.fileWriteUnknown)}
            try png.write(to:directory.appendingPathComponent(name+".png"))
        }
    }
}
