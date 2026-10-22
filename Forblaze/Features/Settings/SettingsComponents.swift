import SwiftUI

/// 設定画面で共用する色・間隔・行。新しい項目も同じ部品で構成する。
enum SettingsStyle {
    static let accent=Color(red:0.82,green:0.29,blue:0.16)
    static let corner:CGFloat=16
    static func canvas(_ scheme:ColorScheme) -> Color {
        scheme == .dark ? Color(white:0.115):Color(red:0.969,green:0.965,blue:0.954)
    }
}

struct SettingsCard<Content:View>:View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @ViewBuilder let content:Content
    var body:some View {
        VStack(alignment:.leading,spacing:0) {content}
            .frame(maxWidth:.infinity,alignment:.leading)
            .background(scheme == .dark ? Color(white:0.16):.white,in:RoundedRectangle(cornerRadius:SettingsStyle.corner))
            .overlay {RoundedRectangle(cornerRadius:SettingsStyle.corner).strokeBorder(.primary.opacity(contrast == .increased ? 0.4:0.07))}
            .shadow(color:.black.opacity(scheme == .dark ? 0:0.025),radius:8,y:3)
    }
}

struct SettingsGroup<Content:View>:View {
    let title:String
    @ViewBuilder let content:Content
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            Text(title).font(.system(size:12,weight:.semibold)).foregroundStyle(.secondary).padding(.leading,2)
                .accessibilityAddTraits(.isHeader)
            content
        }
    }
}

struct SettingsRow<Control:View>:View {
    let title:String
    let detail:String
    @ViewBuilder let control:Control
    var body:some View {
        HStack(alignment:.center,spacing:24) {
            VStack(alignment:.leading,spacing:5) {
                Text(title).font(.system(size:13,weight:.medium)).foregroundStyle(.primary)
                if !detail.isEmpty {
                    Text(detail).font(.system(size:12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal:false,vertical:true).lineSpacing(3)
                }
            }
            Spacer(minLength:0)
            control
        }.padding(18).frame(minHeight:76)
    }
}

struct SettingsToggleRow:View {
    let title:String
    let detail:String
    let identifier:String
    @Binding var isOn:Bool
    var body:some View {
        SettingsRow(title:title,detail:detail) {
            Toggle(title,isOn:$isOn).labelsHidden().toggleStyle(.switch)
                .accessibilityLabel(title).accessibilityHint(detail)
                .accessibilityIdentifier(identifier).frame(minWidth:44,minHeight:40)
        }
    }
}

struct SettingsNote:View {
    let text:String
    var symbol="info.circle"
    var warning=false
    var body:some View {
        HStack(alignment:.top,spacing:9) {
            Image(systemName:symbol).font(.system(size:13)).padding(.top,2).accessibilityHidden(true)
            Text(text).font(.system(size:12)).lineSpacing(4).fixedSize(horizontal:false,vertical:true)
        }
        .foregroundStyle(warning ? Color.primary:Color.secondary)
        .padding(14).frame(maxWidth:.infinity,alignment:.leading)
        .background(warning ? SettingsStyle.accent.opacity(0.09):Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:12))
    }
}

struct SettingsKeycap:View {
    let name:String
    var large=false
    var body:some View {
        Text(name).font(.system(size:large ? 30:18,weight:.medium,design:.rounded))
            .monospacedDigit().padding(.horizontal,large ? 26:18)
            .frame(minWidth:large ? 94:64,minHeight:large ? 80:54)
            .background(.background,in:RoundedRectangle(cornerRadius:large ? 16:12))
            .overlay {RoundedRectangle(cornerRadius:large ? 16:12).strokeBorder(.primary.opacity(0.13))}
            .shadow(color:.black.opacity(0.07),radius:0,y:3)
    }
}

struct SettingsActionStyle:ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var prominent=false
    func makeBody(configuration:Configuration) -> some View {
        SettingsActionLabel(configuration:configuration,prominent:prominent,reduceMotion:reduceMotion)
    }
    private struct SettingsActionLabel:View {
        @Environment(\.isEnabled) private var enabled
        let configuration:Configuration
        let prominent:Bool
        let reduceMotion:Bool
        var body:some View {
            configuration.label.font(.system(size:12,weight:.semibold))
                .padding(.horizontal,15).frame(minHeight:40)
                .foregroundStyle(prominent ? Color.white:Color.primary)
                .background(prominent ? SettingsStyle.accent:Color.primary.opacity(configuration.isPressed ? 0.1:0.055),in:RoundedRectangle(cornerRadius:10))
                .opacity(enabled ? 1:0.4)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96:1)
                .animation(reduceMotion ? nil:.easeOut(duration:0.15),value:configuration.isPressed)
        }
    }
}
