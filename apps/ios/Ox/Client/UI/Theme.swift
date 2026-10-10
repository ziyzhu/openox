import SwiftUI
import UIKit
import os

enum Theme {
    enum Colors {
        static let primary         = DynamicColor(light: 0xFFA500, dark: 0xF5A030)
        static let primaryPressed  = DynamicColor(light: 0xD87A0A, dark: 0xC77410)
        static let surface         = DynamicColor(brand: 0xFFFDF7, light: 0xFFFFFF, dark: 0x1C1C1E)
        static let surfaceSunken   = DynamicColor(brand: 0xFBE9C7, light: 0xF2F2F7, dark: 0x2C2C2E)
        static let chipOnBackground = DynamicColor(brand: 0xFBE9C7, light: 0xFFFFFF, dark: 0x2C2C2E)
        static let chatSurface     = DynamicColor(brand: 0xFFFFFF, light: 0xFFFFFF, dark: 0x0A0A0A)
        static let bubble          = DynamicColor(brand: 0xFBE9C7, light: 0xF2F2F7, dark: 0x1C1C1E)
        static let background      = DynamicColor(brand: 0xFFF6E6, light: 0xF5F5F5, dark: 0x0A0A0A)
        static let onSurface       = DynamicColor(brand: 0x3A2410, light: 0x000000, dark: 0xECECEC)
        static let onSurfaceMuted  = DynamicColor(brand: 0x7A5A3A, light: 0x8E8E93, dark: 0x9A9A9A)
        static let onPrimary       = DynamicColor(light: 0xFFFDF7, dark: 0xFFFDF7)
        static let error           = DynamicColor(light: 0xB8422E, dark: 0xE25A45)
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Radius {
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 18
        static let xl: CGFloat = 24
        static let full: CGFloat = 9999
    }

    enum Size {
        static let chipHeight: CGFloat = 32
        static let minimumTouchTarget: CGFloat = 44
    }

    enum Fonts {
        static let display   = Font.system(.largeTitle,  design: .rounded).weight(.bold)
        static let headline  = Font.system(.title2,      design: .rounded).weight(.semibold)
        static let title     = Font.headline
        static let bodyMd    = Font.body
        static let bodySm    = Font.subheadline
        static let caption   = Font.caption
        static let captionMd = Font.caption.weight(.semibold)
        static let captionSm = Font.caption2.weight(.semibold)
        static let labelMd   = Font.system(.subheadline, design: .rounded).weight(.semibold)
    }

    enum Icons {
        static let xs: Font = .caption2.weight(.semibold)
        static let sm: Font = .caption.weight(.bold)
        static let md: Font = .title3
        static let lg: Font = .title2
        static let xl: Font = .largeTitle
    }

    enum ContainerWidth {
        static let readable: CGFloat = 700
    }

    enum Animation {
        static let press = SwiftUI.Animation.smooth(duration: 0.12)
        static let quick = SwiftUI.Animation.smooth(duration: 0.15)
        static let standard = SwiftUI.Animation.smooth(duration: 0.2)
        static let handoff = SwiftUI.Animation.smooth(duration: 0.24)
        static let drop = SwiftUI.Animation.smooth(duration: 0.35)
        static let ride = SwiftUI.Animation.smooth(duration: 0.45)
        static let streamFade: Double = 0.2
        static let thinkingHold: Double = 1.2
        static let sequenceHold: Double = 1.5
    }
}

nonisolated enum AppTheme: String, CaseIterable, Identifiable {
    case creatorPick
    case light
    case dark

    private static let currentLock = OSAllocatedUnfairLock(initialState: AppTheme.creatorPick)

    static var current: AppTheme {
        get { currentLock.withLock { $0 } }
        set { currentLock.withLock { $0 = newValue } }
    }

    var id: String { rawValue }

    var displayName: LocalizedStringKey {
        switch self {
        case .creatorPick: "Ox"
        case .light: "Light"
        case .dark:  "Dark"
        }
    }

    var colorScheme: ColorScheme {
        switch self {
        case .creatorPick, .light: .light
        case .dark:          .dark
        }
    }
}

private struct AppThemeKey: EnvironmentKey {
    static let defaultValue: AppTheme = .creatorPick
}

extension EnvironmentValues {
    var appTheme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}

struct DynamicColor: ShapeStyle {
    let brand: UInt32
    let light: UInt32
    let dark: UInt32

    init(brand: UInt32, light: UInt32, dark: UInt32) {
        self.brand = brand
        self.light = light
        self.dark = dark
    }

    init(light: UInt32, dark: UInt32) {
        self.init(brand: light, light: light, dark: dark)
    }

    func resolve(in environment: EnvironmentValues) -> Color {
        color(for: environment.appTheme)
    }

    func hex(for theme: AppTheme) -> UInt32 {
        switch theme {
        case .creatorPick: brand
        case .light: light
        case .dark:  dark
        }
    }

    func color(for theme: AppTheme) -> Color {
        Color(uiColor: UIColor(hex: hex(for: theme)))
    }

    var dynamic: Color {
        Color(uiColor: uiColor)
    }

    var uiColor: UIColor {
        let brand = self.brand, light = self.light, dark = self.dark
        return UIColor { _ in UIColor(hex: AppTheme.current.pick(brand, light, dark)) }
    }
}

private extension AppTheme {
    func pick(_ brand: UInt32, _ light: UInt32, _ dark: UInt32) -> UInt32 {
        switch self {
        case .creatorPick: brand
        case .light: light
        case .dark:  dark
        }
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255.0
        let g = CGFloat((hex >> 8) & 0xFF) / 255.0
        let b = CGFloat(hex & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b, alpha: 1.0)
    }
}
