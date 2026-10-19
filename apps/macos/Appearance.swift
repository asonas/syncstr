import SwiftUI

enum AppearancePreference: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: Self { self }
    var title: String {
        switch self {
        case .system: "システムに合わせる"
        case .light: "ライト"
        case .dark: "ダーク"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum AppearanceColors {
    static let content = Color("SurfaceContent")
    static let sidebar = Color("SurfaceSidebar")
    static let control = Color("SurfaceControl")
    static let primary = Color("PrimaryText")
    static let secondary = Color("SecondaryText")
    static let separator = Color("SubtleSeparator")
    static let accent = Color("AccentColor")
    static let action = Color("ActionAccent")
}

struct AppAppearance: ViewModifier {
    @AppStorage("appearance") private var preference = AppearancePreference.system

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(preference.colorScheme)
            .foregroundStyle(AppearanceColors.primary)
            .tint(AppearanceColors.accent)
    }
}

struct AppearanceSettings: View {
    @AppStorage("appearance") private var preference = AppearancePreference.system

    var body: some View {
        Picker("外観", selection: $preference) {
            ForEach(AppearancePreference.allCases) { appearance in
                Text(appearance.title).tag(appearance)
            }
        }
        .accessibilityIdentifier("appearance-picker")
    }
}
