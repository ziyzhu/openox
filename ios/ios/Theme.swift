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

    enum Z {
        static let content:    Double = 0
        static let navigation: Double = 500
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
        static let monoSm    = Font.system(.caption,     design: .monospaced)
    }

    enum Icons {
        static let sm: Font = .caption.weight(.bold)
        static let md: Font = .title3
        static let lg: Font = .title2
        static let xl: Font = .largeTitle
    }

    enum ContainerWidth {
        static let readable: CGFloat = 700
    }

    enum Animation {
        static let quick: Double = 0.15
        static let standard: Double = 0.2
        static let entrance: Double = 0.3
        static let ride = SwiftUI.Animation.timingCurve(0.26, 1, 0.32, 1, duration: 0.6)
        static let drop: Double = 0.4
        static let streamFade: Double = 0.2
        static let thinkingHold: Double = 1.2
        static let sequenceHold: Double = 1.5
        static let glassMorph = SwiftUI.Animation.spring(response: 0.35, dampingFraction: 0.85)
    }
}

extension View {
    func chipSurface<S: ShapeStyle>(_ fill: S) -> some View {
        frame(height: Theme.Size.chipHeight)
            .background(fill, in: Capsule(style: .continuous))
    }

    func contextMenuPreviewShape() -> some View {
        contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous))
    }

    func pressedSurface(_ isPressed: Bool) -> some View {
        opacity(isPressed ? 0.7 : 1.0)
    }

    func minimumTouchTarget(alignment: Alignment = .center) -> some View {
        frame(
            minWidth: Theme.Size.minimumTouchTarget,
            minHeight: Theme.Size.minimumTouchTarget,
            alignment: alignment
        )
        .contentShape(Rectangle())
    }
}

struct OxPressedSurfaceButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .pressedSurface(configuration.isPressed)
    }
}

struct OxChipButton: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var filled: Bool = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Fonts.labelMd)
            .foregroundStyle(filled ? Theme.Colors.onPrimary : Theme.Colors.onSurface)
            .padding(.horizontal, Theme.Spacing.md)
            .chipSurface(
                (filled ? Theme.Colors.primary : Theme.Colors.chipOnBackground)
                    .opacity(configuration.isPressed ? 0.7 : 1.0)
            )
            .minimumTouchTarget()
            .animation(nil, value: filled)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct Chip<Content: View>: View {
    var fill = Theme.Colors.surfaceSunken
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) { content() }
            .padding(.horizontal, Theme.Spacing.md)
            .chipSurface(fill)
    }
}

struct ChipFlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let availableWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var contentWidth: CGFloat = 0
        var contentHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let nextWidth = rowWidth == 0 ? size.width : rowWidth + spacing + size.width
            if rowWidth > 0, nextWidth > availableWidth {
                contentWidth = max(contentWidth, rowWidth)
                contentHeight += rowHeight + spacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth = nextWidth
                rowHeight = max(rowHeight, size.height)
            }
        }

        contentWidth = max(contentWidth, rowWidth)
        contentHeight += rowHeight
        return CGSize(width: proposal.width ?? contentWidth, height: contentHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct SidebarMenuButton: View {
    let action: () -> Void

    @ScaledMetric(relativeTo: .title3) private var size: CGFloat = 44

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Capsule().frame(width: 19, height: 2.5)
                Capsule().frame(width: 12, height: 2.5)
            }
            .foregroundStyle(Theme.Colors.onSurface)
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel(A11yLabel.openSidebar)
        .accessibilityIdentifier(A11yID.Chat.openSidebar)
    }
}

struct SheetDismissToolbarButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                .minimumTouchTarget()
        }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
    }
}

struct TemporaryChatIcon: View {
    let isActive: Bool

    var body: some View {
        Image(isActive ? "icon.temporary.checked" : "icon.temporary")
            .resizable()
            .scaledToFit()
    }
}

nonisolated enum AppTheme: String, CaseIterable, Identifiable {
    case creatorPick
    case light
    case dark

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

@MainActor @Observable final class ThemeManager {
    static let shared = ThemeManager()

    private static let key = "app.theme"
    private static let sharedDefaults = UserDefaults(suiteName: AppStoragePaths.appGroupIdentifier)

    nonisolated private static let currentTheme = OSAllocatedUnfairLock(initialState: AppTheme.creatorPick)
    nonisolated static var current: AppTheme { currentTheme.withLock { $0 } }

    var theme: AppTheme {
        didSet {
            guard oldValue != theme else { return }
            let updatedTheme = theme
            Self.currentTheme.withLock { $0 = updatedTheme }
            Self.sharedDefaults?.set(updatedTheme.rawValue, forKey: Self.key)
            Log.app.info("Theme.select theme=\(updatedTheme.rawValue)")
        }
    }

    private init() {
        let legacyDefaults = UserDefaults.standard
        let sharedValue = Self.sharedDefaults?.string(forKey: Self.key)
        let legacyValue = legacyDefaults.string(forKey: Self.key)
        let storedValue = sharedValue ?? legacyValue
        let stored = storedValue.flatMap(AppTheme.init(rawValue:)) ?? .creatorPick
        theme = stored
        Self.currentTheme.withLock { $0 = stored }
        if let sharedDefaults = Self.sharedDefaults {
            sharedDefaults.set(stored.rawValue, forKey: Self.key)
            let saved = sharedDefaults.synchronize()
            if saved {
                legacyDefaults.removeObject(forKey: Self.key)
                legacyDefaults.synchronize()
            }
            Log.app.info("Theme.restore theme=\(stored.rawValue) source=\(sharedValue == nil && legacyValue != nil ? "legacy" : "shared") saved=\(saved)")
        } else {
            Log.app.error("Theme.restore app-group unavailable")
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

extension View {
    func themed() -> some View { modifier(ThemedModifier()) }
}

private struct ThemedModifier: ViewModifier {
    @State private var manager = ThemeManager.shared

    func body(content: Content) -> some View {
        content
            .environment(\.appTheme, manager.theme)
            .preferredColorScheme(manager.theme.colorScheme)
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
        return UIColor { _ in UIColor(hex: ThemeManager.current.pick(brand, light, dark)) }
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
