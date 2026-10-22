import AppKit
import MetalKit

enum BlazeGeometry {
    static func origin(anchor:NSRect,screen:NSRect)->SIMD2<Float> {
        SIMD2(Float((anchor.midX-screen.minX)/max(1,screen.width)),Float((anchor.midY-screen.minY)/max(1,screen.height)))
    }
    static func drawableSize(points:NSSize,scale:CGFloat,pixelBudget:Double)->NSSize {
        let width=max(1,points.width*scale),height=max(1,points.height*scale)
        let ratio=min(1,sqrt(pixelBudget/(width*height)))
        return NSSize(width:max(1,floor(width*ratio)),height:max(1,floor(height*ratio)))
    }
}

/// 完了ハンドラーとメインスレッドの間で、本文を含まないGPU時間だけを共有する。
final class BlazeGPUFeedback:@unchecked Sendable {
    private let lock=NSLock()
    private var duration:Double=0
    private var failed=false
    func record(duration:Double,failed:Bool) {
        lock.lock();defer {lock.unlock()}
        if duration.isFinite,duration>0 {self.duration=self.duration == 0 ? duration:self.duration*0.9+duration*0.1}
        self.failed=self.failed || failed
    }
    func snapshot()->(duration:Double,failed:Bool) {
        lock.lock();defer {lock.unlock()}
        return (duration,failed)
    }
}

@MainActor final class BlazeMetalView:MTKView {
    override var isOpaque:Bool {false}
    override var acceptsFirstResponder:Bool {false}
    override func hitTest(_ point:NSPoint)->NSView? {nil}
}

@MainActor final class BlazeRenderer:NSObject,MTKViewDelegate {
    let resources:BlazeResources
    var origin=SIMD2<Float>(0.8,0.15)
    var level:()->Float={0}
    var onFinished:(()->Void)?
    var onFailure:(()->Void)?
    private var dynamics=BlazeDynamics()
    private let inflight=DispatchSemaphore(value:2)
    private let feedback=BlazeGPUFeedback()
    private(set) var pixelBudget:Double=2_000_000
    private(set) var submittedFrames=0
    private var didFail=false
    var isBurning:Bool {dynamics.burning}
    init(resources:BlazeResources) {self.resources=resources}
    func setBurning(_ burning:Bool,at time:Double=CACurrentMediaTime()) {dynamics.setBurning(burning,at:time)}
    func stopImmediately() {dynamics.stopImmediately()}
    func resize(_ view:MTKView) {
        let size=BlazeGeometry.drawableSize(points:view.bounds.size,scale:view.window?.backingScaleFactor ?? 2,pixelBudget:pixelBudget)
        if view.drawableSize != size {view.drawableSize=size}
    }
    func mtkView(_ view:MTKView,drawableSizeWillChange size:CGSize) {}
    func draw(in view:MTKView) {
        let frame=dynamics.advance(to:CACurrentMediaTime(),level:level())
        guard frame.isVisible || dynamics.burning else {onFinished?();return}
        let metrics=feedback.snapshot()
        if metrics.failed {
            if !didFail {didFail=true;onFailure?()}
            return
        }
        let constrained=ProcessInfo.processInfo.isLowPowerModeEnabled || ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical
        let nextBudget:Double=constrained || metrics.duration>0.012 ? 1_000_000:2_000_000
        if nextBudget<pixelBudget {pixelBudget=nextBudget;resize(view)}
        let fps=constrained || metrics.duration>0.025 ? 30:60
        if view.preferredFramesPerSecond != fps {view.preferredFramesPerSecond=fps}
        guard inflight.wait(timeout:.now()) == .success else {return}
        guard let pass=view.currentRenderPassDescriptor,let drawable=view.currentDrawable,
              let command=resources.encode(pass:pass,frame:frame,size:SIMD2(Float(view.drawableSize.width),Float(view.drawableSize.height)),origin:origin,particleCount:constrained ? 80:150) else {inflight.signal();return}
        let inflight=self.inflight,feedback=self.feedback
        command.addCompletedHandler {command in
            feedback.record(duration:command.gpuEndTime-command.gpuStartTime,failed:command.status == .error)
            inflight.signal()
        }
        command.present(drawable);command.commit();submittedFrames+=1
    }
}
