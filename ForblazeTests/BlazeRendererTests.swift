import AppKit
import MetalKit
import Testing

struct BlazeRendererTests {
    @Test func flamesSurroundAllFourEdgesAndKeepTheCenterClear() throws {
        let resources=try BlazeResources.make()
        for (width,height) in [(256,144),(144,256),(344,144)] {
            let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:width,height:height,mipmapped:false)
            descriptor.usage = [.renderTarget];descriptor.storageMode = .shared
            let texture=try #require(resources.device.makeTexture(descriptor:descriptor))
            for time:Float in [2.3,18,47] {
                for voice:Float in [0,1] {
                    let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=texture
                    let command=try #require(resources.encode(pass:pass,frame:.init(flame:1,embers:1,ignition:1,voice:voice,time:time),size:SIMD2(Float(width),Float(height)),origin:SIMD2(0.8,0.15)))
                    command.commit();command.waitUntilCompleted()
                    #expect(command.status == .completed)
                    var bytes=[UInt8](repeating:0,count:width*height*4)
                    texture.getBytes(&bytes,bytesPerRow:width*4,from:MTLRegionMake2D(0,0,width,height),mipmapLevel:0)
                    func alpha(_ x:Int,_ y:Int)->UInt8 {bytes[(y*width+x)*4+3]}
                    // 最も強い声でも、中央の半分の幅・高さには炎も火の粉も重ならない。
                    let centerIsClear=(height/4..<height*3/4).allSatisfy {y in
                        (width/4..<width*3/4).allSatisfy {x in alpha(x,y) == 0}
                    }
                    #expect(centerIsClear)
                    // 角を除く各辺を測り、下端だけ燃える退行を検知する。
                    let top=(width/3..<width*2/3).map {alpha($0,height/50)}
                    let bottom=(width/3..<width*2/3).map {alpha($0,height-1-height/50)}
                    let left=(height/3..<height*2/3).map {alpha(width/50,$0)}
                    let right=(height/3..<height*2/3).map {alpha(width-1-width/50,$0)}
                    for edge in [top,bottom,left,right] {#expect(edge.filter {$0>80}.count>edge.count/2)}
                }
            }
        }
    }

    @Test func productionShaderIsTransparentWhenOffAndDrawsWarmFlamesWhenOn() throws {
        let resources=try BlazeResources.make()
        let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:256,height:144,mipmapped:false)
        descriptor.usage = [.renderTarget];descriptor.storageMode = .shared
        let texture=try #require(resources.device.makeTexture(descriptor:descriptor))
        func pixels(_ frame:BlazeDynamics.Frame) throws -> [UInt8] {
            let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=texture
            let command=try #require(resources.encode(pass:pass,frame:frame,size:SIMD2(256,144),origin:SIMD2(0.8,0.15)))
            command.commit();command.waitUntilCompleted()
            #expect(command.status == .completed)
            var bytes=[UInt8](repeating:0,count:256*144*4)
            texture.getBytes(&bytes,bytesPerRow:256*4,from:MTLRegionMake2D(0,0,256,144),mipmapLevel:0)
            return bytes
        }
        #expect(try pixels(.init()).allSatisfy {$0 == 0})
        let warm=try pixels(.init(flame:1,embers:1,ignition:1,voice:0.65,time:18))
        var glowing=0,transparent=0
        for i in stride(from:0,to:warm.count,by:4) {
            if warm[i+3]>80 && warm[i+2]>warm[i] {glowing+=1}
            if warm[i+3]<20 {transparent+=1}
            #expect(warm[i]<=warm[i+3] && warm[i+1]<=warm[i+3] && warm[i+2]<=warm[i+3])
        }
        #expect(glowing>256*144/4 && transparent>256*144/10)
        #expect(try pixels(.init(flame:1,embers:1,ignition:1,voice:0.65,time:19)) != warm)
    }
}
