import AppKit
import ForblazeCore

/// 18ptのドット絵。待機はOSが明暗に合わせる輪郭、収録中は暖色の塗り。
@MainActor enum StatusBarIcon {
    private static let outline=makeImage(recording:false)
    private static let burning=makeImage(recording:true)

    static func image(for state:SessionState) -> NSImage {
        // 入力保留中もマイク収録は続く。文字入力の可否とは分けて示す。
        state.phase == .listening ? burning:outline
    }

    private static func makeImage(recording:Bool) -> NSImage {
        let rows=[
            ".....#......",
            ".....##.....",
            "....###.....",
            "....####....",
            "...#####....",
            "...#####.#..",
            "..#####.##..",
            "..########..",
            ".##########.",
            ".##########.",
            "############",
            "############",
            ".##########.",
            ".##########.",
            "..########..",
            "....####...."
        ].map {Array($0)}
        func occupied(_ x:Int,_ y:Int) -> Bool {
            y>=0 && y<rows.count && x>=0 && x<rows[y].count && rows[y][x]=="#"
        }
        let image=NSImage(size:NSSize(width:18,height:18))
        for scale in [1,2] {
            let side=18*scale
            guard let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:side,pixelsHigh:side,
                bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,
                bitmapFormat:.alphaNonpremultiplied,bytesPerRow:side*4,bitsPerPixel:32),
                  let bytes=bitmap.bitmapData else {continue}
            bytes.initialize(repeating:0,count:side*side*4)
            for y in 0..<16 {
                for x in 0..<12 where occupied(x,y) {
                    let edge = !occupied(x-1,y) || !occupied(x+1,y) || !occupied(x,y-1) || !occupied(x,y+1)
                    guard recording || edge else {continue}
                    let color:(UInt8,UInt8,UInt8)
                    if !recording {color=(0,0,0)}
                    else if edge {color=(224,79,32)}
                    else if y>=10 && y<=13 && x>=5 && x<=6 {color=(255,239,169)}
                    else if y>=7 && x>=4 && x<=7 {color=(255,198,63)}
                    else {color=(255,132,37)}
                    for dy in 0..<scale {
                        for dx in 0..<scale {
                            let offset=(((y+1)*scale+dy)*side+(x+3)*scale+dx)*4
                            bytes[offset]=color.0;bytes[offset+1]=color.1;bytes[offset+2]=color.2;bytes[offset+3]=255
                        }
                    }
                }
            }
            bitmap.size=image.size
            image.addRepresentation(bitmap)
        }
        image.isTemplate = !recording
        return image
    }
}
