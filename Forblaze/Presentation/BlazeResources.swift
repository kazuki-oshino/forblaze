import Metal
import Foundation

enum BlazeRenderError:Error {case deviceUnavailable, shaderUnavailable}

/// パイプラインは生成後に変更しない。Metalのオブジェクトを描画スレッドへ渡す。
final class BlazeResources:Sendable {
    let device:any MTLDevice
    let queue:any MTLCommandQueue
    let flame:any MTLRenderPipelineState
    let sparks:any MTLRenderPipelineState
    private init(device:any MTLDevice,queue:any MTLCommandQueue,flame:any MTLRenderPipelineState,sparks:any MTLRenderPipelineState) {
        self.device=device;self.queue=queue;self.flame=flame;self.sparks=sparks
    }
    static func make() throws -> BlazeResources {
        guard let device=MTLCreateSystemDefaultDevice(),let queue=device.makeCommandQueue() else {throw BlazeRenderError.deviceUnavailable}
        let library=try device.makeLibrary(source:BlazeShader.source,options:nil)
        func pipeline(vertex:String,fragment:String) throws -> any MTLRenderPipelineState {
            guard let v=library.makeFunction(name:vertex),let f=library.makeFunction(name:fragment) else {throw BlazeRenderError.shaderUnavailable}
            let descriptor=MTLRenderPipelineDescriptor()
            descriptor.vertexFunction=v;descriptor.fragmentFunction=f
            let color=descriptor.colorAttachments[0]!
            color.pixelFormat = .bgra8Unorm;color.isBlendingEnabled=true
            color.sourceRGBBlendFactor = .one;color.destinationRGBBlendFactor = .oneMinusSourceAlpha
            color.sourceAlphaBlendFactor = .one;color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try device.makeRenderPipelineState(descriptor:descriptor)
        }
        return try BlazeResources(device:device,queue:queue,flame:pipeline(vertex:"blazeVertex",fragment:"blazeFragment"),sparks:pipeline(vertex:"sparkVertex",fragment:"sparkFragment"))
    }

    func encode(pass:MTLRenderPassDescriptor,frame:BlazeDynamics.Frame,size:SIMD2<Float>,origin:SIMD2<Float>,particleCount:Int=150)->(any MTLCommandBuffer)? {
        guard let command=queue.makeCommandBuffer() else {return nil}
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0)
        guard let encoder=command.makeRenderCommandEncoder(descriptor:pass) else {return nil}
        let uniforms=[SIMD4(size.x,size.y,origin.x,origin.y),SIMD4(frame.time,frame.flame,frame.embers,frame.voice),SIMD4(frame.ignition,max(1,size.y/900),0,0)]
        uniforms.withUnsafeBytes {bytes in
            encoder.setFragmentBytes(bytes.baseAddress!,length:bytes.count,index:0)
            encoder.setVertexBytes(bytes.baseAddress!,length:bytes.count,index:0)
        }
        encoder.setRenderPipelineState(flame)
        encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3)
        if frame.embers>0 {
            encoder.setRenderPipelineState(sparks)
            encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6,instanceCount:max(0,min(particleCount,200)))
        }
        encoder.endEncoding()
        return command
    }
}
