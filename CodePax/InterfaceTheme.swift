import SwiftUI

enum InterfaceSkin: String, CaseIterable, Identifiable {
    case classic, companion
    var id: String { rawValue }
    var title: String { self == .classic ? "经典工作台" : "角色主题" }
    var symbol: String { self == .classic ? "rectangle.3.group" : "person.crop.square" }
}

enum InterfacePalette: String, CaseIterable, Identifiable {
    case violet, ocean, jade, rose, amber, graphite
    var id: String { rawValue }
    var title: String {
        switch self { case .violet: return "紫藤"; case .ocean: return "海蓝"; case .jade: return "青竹"
        case .rose: return "樱粉"; case .amber: return "琥珀"; case .graphite: return "石墨" }
    }
    var ink: UInt32 {
        switch self { case .violet: return 0x6e4dad; case .ocean: return 0x176a8a; case .jade: return 0x246b53
        case .rose: return 0x9c3b64; case .amber: return 0x825c18; case .graphite: return 0x4b5969 }
    }
    var highlight: UInt32 {
        switch self { case .violet: return 0xbda6f5; case .ocean: return 0x88c9f0; case .jade: return 0x86d4b1
        case .rose: return 0xefa9c3; case .amber: return 0xedcd87; case .graphite: return 0xb8c4d2 }
    }
    func color(dark: Bool) -> Color { Self.blend(dark ? highlight : ink, base: 0, amount: 1) }
    static func blend(_ rgb: UInt32, base: Double, amount: Double) -> Color {
        func component(_ shift: UInt32) -> Double { base * (1 - amount) + Double((rgb >> shift) & 255) / 255 * amount }
        return Color(red: component(16), green: component(8), blue: component(0))
    }
}

struct PalettePicker: View {
    @AppStorage("interfacePalette") private var palette = InterfacePalette.violet.rawValue
    var body: some View {
        Picker("配色", selection: $palette) {
            ForEach(InterfacePalette.allCases) { value in
                Label { Text(value.title) } icon: { Image(systemName: "circle.fill").foregroundStyle(value.color(dark: false)) }.tag(value.rawValue)
            }
        }
    }
}

struct InterfaceTheme {
    let skin: InterfaceSkin
    let colorScheme: ColorScheme
    var palette: InterfacePalette = .violet
    var isCompanion: Bool { skin == .companion }
    private var dark: Bool { colorScheme == .dark }
    var accent: Color {
        if palette != .violet { return palette.color(dark: dark) }
        guard isCompanion else { return .blue }
        return dark ? Color(red:0.74,green:0.65,blue:0.96) : Color(red:0.43,green:0.30,blue:0.67)
    }
    var actionFill: Color {
        if palette != .violet { return palette.color(dark: false) }
        return isCompanion ? Color(red:0.43,green:0.30,blue:0.68) : Color(red:0.13,green:0.39,blue:0.88)
    }
    var canvas: Color {
        if isCompanion, palette != .violet { return InterfacePalette.blend(palette.highlight, base: dark ? 0.035 : 1, amount: dark ? 0.065 : 0.025) }
        guard isCompanion else { return Color(.systemBackground) }
        return dark ? Color(red:0.067,green:0.059,blue:0.088) : Color(red:0.976,green:0.969,blue:0.990)
    }
    var sidebar: Color {
        if isCompanion, palette != .violet { return InterfacePalette.blend(palette.highlight, base: dark ? 0.035 : 1, amount: dark ? 0.14 : 0.08) }
        guard isCompanion else { return Color(.secondarySystemBackground) }
        return dark ? Color(red:0.105,green:0.090,blue:0.136) : Color(red:0.941,green:0.925,blue:0.972)
    }
    var card: Color {
        if isCompanion, palette != .violet { return InterfacePalette.blend(palette.highlight, base: dark ? 0.035 : 1, amount: dark ? 0.2 : 0.01) }
        guard isCompanion else { return Color(.secondarySystemGroupedBackground) }
        return dark ? Color(red:0.137,green:0.118,blue:0.176) : Color(red:0.998,green:0.991,blue:1)
    }
    var input: Color {
        if isCompanion, palette != .violet { return InterfacePalette.blend(palette.highlight, base: dark ? 0.035 : 1, amount: dark ? 0.26 : 0.05) }
        guard isCompanion else { return card }
        return dark ? Color(red:0.174,green:0.149,blue:0.218) : Color(red:0.959,green:0.945,blue:0.983)
    }
    var userBubble: Color {
        if isCompanion, palette != .violet { return InterfacePalette.blend(palette.highlight, base: dark ? 0.035 : 1, amount: dark ? 0.38 : 0.15) }
        guard isCompanion else { return Color(.tertiarySystemFill) }
        return dark ? Color(red:0.279,green:0.224,blue:0.365) : Color(red:0.882,green:0.837,blue:0.958)
    }
    var border: Color { isCompanion ? accent.opacity(dark ? 0.22 : 0.15) : Color.primary.opacity(0.10) }
    var chrome: AnyShapeStyle { isCompanion ? AnyShapeStyle(sidebar) : AnyShapeStyle(.bar) }
    var selection: Color { isCompanion ? accent.opacity(dark ? 0.18 : 0.11) : Color.primary.opacity(0.07) }
}

private struct InterfaceThemeKey: EnvironmentKey {
    static let defaultValue = InterfaceTheme(skin: .classic, colorScheme: .light)
}
extension EnvironmentValues {
    var interfaceTheme: InterfaceTheme {
        get { self[InterfaceThemeKey.self] }
        set { self[InterfaceThemeKey.self] = newValue }
    }
}

struct SkinPicker: View {
    @AppStorage("interfaceSkin") private var skin = InterfaceSkin.classic.rawValue
    var body: some View {
        Picker("界面皮肤", selection: $skin) {
            ForEach(InterfaceSkin.allCases) { Label($0.title, systemImage: $0.symbol).tag($0.rawValue) }
        }
    }
}
