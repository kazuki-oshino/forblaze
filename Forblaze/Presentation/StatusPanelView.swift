import SwiftUI

/// 入力先の文章と重複しない、状態と音量だけのパネル。
@MainActor struct StatusPanelView:View {
    let model:DictationViewModel
    var animationEnabled=true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let coral=Color(red:1,green:0.29,blue:0.32)
    private var accent:Color {model.errorText == nil ? (model.forblazeMode && reduceMotion ? .orange:coral) : .orange}
    var body:some View {
        TimelineView(.animation(minimumInterval:1.0/24,paused:!animationEnabled || reduceMotion || !model.hasRecordingAppearance)) { context in
            let time=reduceMotion || !animationEnabled ? 0 : context.date.timeIntervalSinceReferenceDate
            surface(time:time)
        }
        .preferredColorScheme(.dark)
    }
    private func surface(time:Double)->some View {
        let shape=RoundedRectangle(cornerRadius:22,style:.continuous)
        let active=model.hasRecordingAppearance
        let sweep=AngularGradient(stops:[
            .init(color:accent.opacity(0.10),location:0),
            .init(color:accent.opacity(0.16),location:0.40),
            .init(color:accent.opacity(0.55),location:0.65),
            .init(color:Color(red:1,green:0.67,blue:0.64),location:0.78),
            .init(color:accent.opacity(0.72),location:0.84),
            .init(color:accent.opacity(0.10),location:1)
        ],center:.center,startAngle:.degrees(time.truncatingRemainder(dividingBy:4)*90),endAngle:.degrees(time.truncatingRemainder(dividingBy:4)*90+360))
        return VStack(alignment:.leading,spacing:10) {
            HStack(spacing:9) {
                Image(systemName:model.errorText == nil ? "waveform" : "exclamationmark")
                    .font(.system(size:13,weight:.semibold))
                    .foregroundStyle(active ? coral : .white.opacity(0.75))
                    .frame(width:26,height:26)
                    .background((active ? coral : .white).opacity(0.09),in:RoundedRectangle(cornerRadius:9))
                Text("forblaze").font(.system(size:15,weight:.semibold)).tracking(0.2).foregroundStyle(.white.opacity(0.94))
                Spacer(minLength:8)
                HStack(spacing:5) {
                    Circle().fill(active ? coral : .white.opacity(0.35)).frame(width:5,height:5)
                    Text(model.panelTitle).font(.system(size:10,weight:.medium))
                }
                .foregroundStyle(.white.opacity(active ? 0.88:0.62))
                .padding(.horizontal,8).padding(.vertical,5)
                .background(.white.opacity(0.045),in:Capsule())
            }
            waveform(time:time,active:active).frame(height:16).accessibilityHidden(true)
            if let progress=model.modelProgress {
                VStack(alignment:.leading,spacing:5) {
                    Text("日本語モデルを準備中").font(.system(size:10)).foregroundStyle(.white.opacity(0.65))
                    GeometryReader { geometry in
                        ZStack(alignment:.leading) {
                            Capsule().fill(.white.opacity(0.08))
                            Capsule().fill(coral).frame(width:geometry.size.width*(progress.isFinite ? min(max(progress,0),1):0))
                        }
                    }.frame(height:3)
                }
            }
            if let help=model.suspensionHelp {
                Text(help).font(.system(size:11)).foregroundStyle(.white.opacity(0.72)).fixedSize(horizontal:false,vertical:true)
            }
            if let error=model.errorText {
                Text(error).font(.system(size:11)).foregroundStyle(.orange.opacity(0.95)).fixedSize(horizontal:false,vertical:true)
            }
            if let help=model.recoveryHelp {
                Text(help).font(.system(size:11)).foregroundStyle(.white.opacity(0.72)).fixedSize(horizontal:false,vertical:true)
            }
        }
        .padding(16)
        .frame(width:292,height:model.panelHeight,alignment:.topLeading)
        .background {
            shape.fill(.ultraThinMaterial).overlay(shape.fill(Color(white:0.055).opacity(0.87)))
        }
        .overlay(shape.strokeBorder(.white.opacity(0.065),lineWidth:0.7))
        .overlay {
            if active {
                shape.stroke(sweep,lineWidth:2.5).blur(radius:7).opacity(0.7)
                shape.stroke(sweep,lineWidth:1.2)
            } else if model.errorText != nil {
                shape.strokeBorder(.orange.opacity(0.32),lineWidth:0.8)
            }
        }
        .shadow(color:.black.opacity(0.28),radius:10,y:5)
        .padding(16)
        .accessibilityElement(children:.combine)
    }
    private func waveform(time:Double,active:Bool)->some View {
        Canvas { context,size in
            let bars=40,spacing=3.0
            let width=(size.width-Double(bars-1)*spacing)/Double(bars)
            let level=active && model.level.isFinite ? min(max(Double(model.level)*20,0),1) : 0
            for index in 0..<bars {
                let rhythm=0.30+0.70*abs(sin(Double(index)*0.57+time*3.1))
                let height=3+level*13*rhythm
                let rect=CGRect(x:Double(index)*(width+spacing),y:(size.height-height)/2,width:width,height:height)
                context.fill(Path(roundedRect:rect,cornerRadius:2),with:.color(.white.opacity(active ? 0.78:0.28)))
            }
        }
    }
}
