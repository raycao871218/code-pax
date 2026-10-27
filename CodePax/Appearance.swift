import SwiftUI
import UIKit

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self { case .system: return "跟随系统"; case .light: return "浅色"; case .dark: return "深色" }
    }
    var colorScheme: ColorScheme? {
        switch self { case .system: return nil; case .light: return .light; case .dark: return .dark }
    }
}

struct AppearancePicker: View {
    @AppStorage("appearance") private var appearance = AppearanceMode.system.rawValue
    var body: some View {
        Picker("外观", selection: $appearance) {
            ForEach(AppearanceMode.allCases) { Text($0.title).tag($0.rawValue) }
        }
    }
}

/// Update the window's traits, including presentations that are already visible.
struct AppAppearanceModifier: ViewModifier {
    @AppStorage private var appearance: String
    @AppStorage private var skin: String
    @AppStorage private var palette: String
    @Environment(\.colorScheme) private var systemScheme

    init(store: UserDefaults = .standard) {
        _appearance = AppStorage(wrappedValue: AppearanceMode.system.rawValue, "appearance", store: store)
        _palette = AppStorage(wrappedValue: InterfacePalette.violet.rawValue, "interfacePalette", store: store)
        _skin = AppStorage(wrappedValue: InterfaceSkin.classic.rawValue, "interfaceSkin", store: store)
    }

    private func resolvedPreferences() -> (AppearanceMode, InterfaceSkin) {
        var mode = AppearanceMode(rawValue: appearance) ?? .system
        var selectedSkin = InterfaceSkin(rawValue: skin) ?? .classic
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--preview-workspace") || args.contains("--preview-connections") || args.contains("--preview-markdown-file") || args.contains("--preview-terminal") || args.contains("--preview-customization") {
            if args.contains("--preview-companion") { selectedSkin = .companion }
            if args.contains("--preview-classic") { selectedSkin = .classic }
            if args.contains("--preview-light") { mode = .light }
            if args.contains("--preview-dark") { mode = .dark }
        }
        #endif
        return (mode, selectedSkin)
    }

    private func resolvedPalette() -> InterfacePalette {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains(where: { $0.hasPrefix("--preview-") }),
           let flag = args.first(where: { $0.hasPrefix("--preview-palette=") }),
           let value = InterfacePalette(rawValue: String(flag.dropFirst("--preview-palette=".count))) { return value }
        #endif
        return InterfacePalette(rawValue: palette) ?? .violet
    }

    func body(content: Content) -> some View {
        let (mode, selectedSkin) = resolvedPreferences()
        let scheme = mode.colorScheme ?? systemScheme
        let theme = InterfaceTheme(skin: selectedSkin, colorScheme: scheme, palette: resolvedPalette())
        content.environment(\.interfaceTheme, theme).tint(theme.accent).background {
            WindowAppearanceBridge(mode: mode)
                .frame(width: 0, height: 0).allowsHitTesting(false)
        }
    }
}

private struct WindowAppearanceBridge: UIViewRepresentable {
    let mode: AppearanceMode
    func makeUIView(context: Context) -> AppearanceWindowObserver { AppearanceWindowObserver() }
    func updateUIView(_ view: AppearanceWindowObserver, context: Context) {
        switch mode {
        case .system: view.style = .unspecified
        case .light: view.style = .light
        case .dark: view.style = .dark
        }
        view.apply()
    }
}

private final class AppearanceWindowObserver: UIView {
    var style: UIUserInterfaceStyle = .unspecified
    override func didMoveToWindow() {
        super.didMoveToWindow()
        apply()
    }
    func apply() {
        guard let window, window.overrideUserInterfaceStyle != style else { return }
        window.overrideUserInterfaceStyle = style
    }
}

extension View {
    func appAppearance(store: UserDefaults = .standard) -> some View {
        modifier(AppAppearanceModifier(store: store))
    }
}
