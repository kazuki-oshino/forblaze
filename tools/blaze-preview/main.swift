import AppKit
import SwiftUI
import MetalKit
import ForblazeCore
import ForblazeApplication

@MainActor private final class PreviewPosition:PanelPositionStore {
    func load()->PanelPosition? {nil}
    func save(_ position:PanelPosition) {}
}

@main struct BlazePreview {
    @MainActor static func main() throws {
        _=NSApplication.shared
        let directory=URL(fileURLWithPath:CommandLine.arguments[1])
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        if CommandLine.arguments.count>2,CommandLine.arguments[2]=="--live" {
            Task { @MainActor in
                do {try await live(directory:directory,seconds:Double(CommandLine.arguments.last ?? "12") ?? 12)}
                catch {print("演出の実行検証に失敗: \(error)");exit(1)}
                NSApplication.shared.terminate(nil)
            }
            NSApplication.shared.run()
            return
        }
        let resources=try BlazeResources.make()
        let width=1440,height=900
        let textureDescriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:width,height:height,mipmapped:false)
        textureDescriptor.usage = [.renderTarget];textureDescriptor.storageMode = .shared
        guard let texture=resources.device.makeTexture(descriptor:textureDescriptor) else {throw BlazeRenderError.deviceUnavailable}
        let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=texture
        let origin=SIMD2<Float>(Float(width-186)/Float(width),74.0/Float(height))
        var durations:[Double]=[]
        for frameIndex in 0..<190 {
            let frame=BlazeDynamics.Frame(flame:1,embers:1,ignition:1,voice:0.65,time:18+Float(frameIndex)/60)
            guard let command=resources.encode(pass:pass,frame:frame,size:SIMD2(Float(width),Float(height)),origin:origin) else {throw BlazeRenderError.shaderUnavailable}
            command.commit();command.waitUntilCompleted()
            guard command.status == .completed else {throw BlazeRenderError.shaderUnavailable}
            if frameIndex>=10 {durations.append((command.gpuEndTime-command.gpuStartTime)*1000)}
            if frameIndex == 10 || frameIndex == 100 {
                let fire=try image(texture:texture,width:width,height:height)
                for dark in [true,false] {try composite(fire:fire,dark:dark,width:width,height:height).write(to:directory.appendingPathComponent("blaze-\(dark ? "dark":"light")-\(frameIndex).png"))}
            }
        }
        durations.sort()
        let metrics:[String:Any]=["device":resources.device.name,"renderWidth":width,"renderHeight":height,"frames":durations.count,"gpuP50Milliseconds":durations[durations.count/2],"gpuP95Milliseconds":durations[Int(Double(durations.count)*0.95)],"microphone":false]
        let data=try JSONSerialization.data(withJSONObject:metrics,options:[.prettyPrinted,.sortedKeys])
        try data.write(to:directory.appendingPathComponent("gpu-metrics.json"))
        print(String(decoding:data,as:UTF8.self))
    }

    @MainActor static func image(texture:any MTLTexture,width:Int,height:Int) throws -> NSImage {
        var bytes=[UInt8](repeating:0,count:width*height*4)
        texture.getBytes(&bytes,bytesPerRow:width*4,from:MTLRegionMake2D(0,0,width,height),mipmapLevel:0)
        guard let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width,pixelsHigh:height,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:width*4,bitsPerPixel:32),let data=bitmap.bitmapData else {throw CocoaError(.fileWriteUnknown)}
        for i in stride(from:0,to:bytes.count,by:4) {data[i]=bytes[i+2];data[i+1]=bytes[i+1];data[i+2]=bytes[i];data[i+3]=bytes[i+3]}
        let image=NSImage(size:NSSize(width:width,height:height));image.addRepresentation(bitmap)
        return image
    }

    @MainActor static func composite(fire:NSImage,dark:Bool,width:Int,height:Int) throws -> Data {
        let model=DictationViewModel(toggle:{})
        var state=SessionState();let id=SessionID();_=state.handle(.toggle(id));_=state.handle(.prepared(id,.init(1)))
        model.update(state:state,preview:"");model.level=0.035;model.forblazeMode=true
        let content=ZStack(alignment:.bottomTrailing) {
            Color(white:dark ? 0.10:0.88)
            VStack(alignment:.leading,spacing:22) {
                Text("forblaze 演出プレビュー").font(.system(size:14)).foregroundStyle(.secondary)
                Text("四辺は燃えても、言葉は見える。").font(.system(size:32,weight:.medium))
                Text("上下左右から流れる炎と火の粉。\n中央には、入力中の文章が見える余白を残します。")
                    .font(.system(size:17)).lineSpacing(8)
                Text("マイクを使わず、本番のMetal描画を確認しています。")
                    .font(.system(size:14)).foregroundStyle(.secondary)
            }.frame(width:760,alignment:.leading).frame(maxWidth:.infinity,maxHeight:.infinity)
            Image(nsImage:fire).resizable().frame(width:CGFloat(width),height:CGFloat(height))
            StatusPanelView(model:model,animationEnabled:false).padding(.trailing,24).padding(.bottom,16)
        }.frame(width:CGFloat(width),height:CGFloat(height)).environment(\.colorScheme,dark ? .dark:.light)
        let renderer=ImageRenderer(content:content);renderer.scale=1
        guard let image=renderer.nsImage,let tiff=image.tiffRepresentation,let bitmap=NSBitmapImageRep(data:tiff),let png=bitmap.representation(using:.png,properties:[:]) else {throw CocoaError(.fileWriteUnknown)}
        return png
    }

    @MainActor static func live(directory:URL,seconds:Double) async throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let model=DictationViewModel(toggle:{});model.forblazeMode=true
        let panel=StatusPanelController(model:model,store:PreviewPosition())
        let overlay=BlazeOverlayController(model:model,anchor:panel.panel)
        defer {overlay.shutdown();panel.panel.orderOut(nil)}
        let keyWindowBefore=NSApplication.shared.keyWindow?.windowNumber
        overlay.refresh();await overlay.waitUntilPrepared()
        guard overlay.renderer != nil else {throw BlazeRenderError.deviceUnavailable}
        var state=SessionState();let id=SessionID();_=state.handle(.toggle(id));_=state.handle(.prepared(id,.init(1)))
        model.update(state:state,preview:"")
        panel.update(size:NSSize(width:324,height:116),visible:true);overlay.refresh()
        let start=CACurrentMediaTime(),duration=min(max(seconds,2),60)
        while CACurrentMediaTime()-start<duration {
            model.level=Float(0.025+sin((CACurrentMediaTime()-start)*2)*0.02)
            try await Task.sleep(for:.milliseconds(16))
        }
        let frames=overlay.renderer?.submittedFrames ?? 0
        _=state.handle(.toggle(id));model.update(state:state,preview:"");overlay.refresh()
        try await Task.sleep(for:.milliseconds(1200))
        let stoppedFrames=overlay.renderer?.submittedFrames ?? 0
        let hidden=overlay.panel?.isVisible == false,paused=overlay.metalView?.isPaused == true
        try await Task.sleep(for:.milliseconds(300))
        let metrics:[String:Any]=["seconds":duration,"framesWhileBurning":frames,"observedFramesPerSecond":Double(frames)/duration,"hiddenAfterCooling":hidden,"pausedAfterCooling":paused,"noDrawsAfterCooling":stoppedFrames == overlay.renderer?.submittedFrames,"preservedKeyWindow":keyWindowBefore == NSApplication.shared.keyWindow?.windowNumber,"clickThrough":overlay.panel?.ignoresMouseEvents == true,"microphone":false]
        let data=try JSONSerialization.data(withJSONObject:metrics,options:[.prettyPrinted,.sortedKeys])
        try data.write(to:directory.appendingPathComponent("live-metrics.json"))
        print(String(decoding:data,as:UTF8.self))
        guard hidden,paused,stoppedFrames == overlay.renderer?.submittedFrames,frames>0 else {throw BlazeRenderError.shaderUnavailable}
    }
}
