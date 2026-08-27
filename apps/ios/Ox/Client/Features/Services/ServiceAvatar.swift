import SwiftUI
import UIKit

enum ServiceAvatarShape { case roundedRect(CGFloat), circle }

@MainActor
private enum ServiceAvatarCache {
    static var images: [String: UIImage] = [:]
}

struct ServiceAvatar: View {
    private enum FaviconState {
        case loading
        case loaded(UIImage)
        case unavailable
    }

    let service: Service
    let size: CGFloat
    let shape: ServiceAvatarShape
    var monogramSize: CGFloat = 22
    @Environment(ServiceManager.self) private var serviceManager
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var faviconState = FaviconState.loading

    var body: some View {
        ZStack {
            if isLoadingFavicon {
                FaviconShimmer(size: size, shape: shape)
            } else {
                if favicon == nil {
                    background
                }
                content
                    .frame(width: size, height: size)
                    .clipShape(clipShape)
            }
        }
        .frame(width: size, height: size)
        .task(id: "\(service.domain):\(colorScheme)") {
            guard service.webService != nil || service.isMCPService else { return }
            let theme = colorScheme == .dark ? "dark" : "light"
            let cacheKey = service.isMCPService ? "\(service.domain):\(theme)" : service.domain
            if let image = ServiceAvatarCache.images[cacheKey] {
                faviconState = .loaded(image)
                return
            }
            faviconState = .loading
            guard let image = await serviceManager.faviconImage(for: service.domain, preferredTheme: theme).flatMap(UIImage.init) else {
                faviconState = .unavailable
                return
            }
            guard !Task.isCancelled else { return }
            ServiceAvatarCache.images[cacheKey] = image
            withAnimation(reduceMotion ? nil : .easeOut(duration: Theme.Animation.quick)) {
                faviconState = .loaded(image)
            }
        }
    }

    private var favicon: UIImage? {
        guard case .loaded(let image) = faviconState else { return nil }
        return image
    }

    private var isLoadingFavicon: Bool {
        guard service.webService != nil || service.isMCPService else { return false }
        if case .loading = faviconState { return true }
        return false
    }

    @ViewBuilder
    private var background: some View {
        switch shape {
        case .roundedRect(let r):
            RoundedRectangle(cornerRadius: r, style: .continuous).fill(service.tint)
        case .circle:
            Circle().fill(service.tint)
        }
    }

    private var clipShape: AnyShape {
        switch shape {
        case .roundedRect(let r): AnyShape(RoundedRectangle(cornerRadius: r, style: .continuous))
        case .circle: AnyShape(Circle())
        }
    }

    @ViewBuilder
    private var content: some View {
        if let favicon {
            Image(uiImage: favicon).resizable().scaledToFill()
        } else if let icon = service.icon {
            switch icon {
            case .asset(let name):
                Image(name)
                    .resizable()
                    .scaledToFill()
            case .system(let name):
                Image(systemName: name)
                    .resizable()
                    .scaledToFit()
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(Theme.Colors.onPrimary)
                    .padding(size * 0.12)
            }
        } else {
            monogram
        }
    }

    private var monogram: some View {
        Text(service.monogram)
            .font(.system(size: monogramSize, weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.Colors.onPrimary)
    }
}

private struct FaviconShimmer: View {
    nonisolated private static let travel: CGFloat = 1.6

    let size: CGFloat
    let shape: ServiceAvatarShape
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        clipShape
            .fill(Color(uiColor: .systemGray6))
            .keyframeAnimator(initialValue: -Self.travel, repeating: !reduceMotion) { content, position in
                content
                    .overlay {
                        Rectangle()
                            .fill(shimmerGradient)
                            .frame(width: size * 0.7)
                            .rotationEffect(.degrees(18))
                            .offset(x: size * position)
                    }
                    .clipShape(clipShape)
            } keyframes: { _ in
                LinearKeyframe(Self.travel, duration: 1.2)
                LinearKeyframe(Self.travel, duration: 0.35)
            }
    }

    private var shimmerGradient: LinearGradient {
        LinearGradient(
            colors: [
                .clear,
                .white.opacity(colorScheme == .dark ? 0.12 : 0.65),
                .clear,
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private var clipShape: AnyShape {
        switch shape {
        case .roundedRect(let radius): AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        case .circle: AnyShape(Circle())
        }
    }
}

struct ServiceChip: View {
    private enum AuthStatus {
        case signedIn
        case signedOut
        case loading
    }

    let service: Service?
    let title: String
    var onOpen: (() -> Void)? = nil
    var showsAuthStatus = false
    var onRemove: (() -> Void)? = nil
    var removeAccessibilityIdentifier: String? = nil
    var fill = Theme.Colors.surfaceSunken
    var surfaceOpacity = 1.0

    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        chipContent
            .task(id: "\(service?.id ?? "none"):\(scenePhase)") {
                guard showsAuthStatus, scenePhase == .active, let service else { return }
                await service.resolveAccess(reason: .chatOpen)
            }
    }

    @ViewBuilder
    private var chipContent: some View {
        if showsAuthStatus, let onOpen {
            Button(action: onOpen) {
                statusChip
                    .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(OxPressedSurfaceButtonStyle())
            .accessibilityLabel(title)
            .accessibilityValue(accessibilityValue)
            .accessibilityIdentifier(service.map { A11yID.Chat.servicePill($0.domain) } ?? "")
        } else {
            chip
        }
    }

    private var statusChip: some View {
        HStack(spacing: 6) {
            label
            signInStatusIcon
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .chipSurface(fill.opacity(surfaceOpacity))
    }

    private var chip: some View {
        HStack(spacing: 6) {
            if let onOpen {
                Button(action: onOpen) {
                    label
                }
                .buttonStyle(OxPressedSurfaceButtonStyle())
                .accessibilityLabel(title)
                .accessibilityValue(accessibilityValue)
                .accessibilityIdentifier(service.map { A11yID.Chat.servicePill($0.domain) } ?? "")
            } else {
                label
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(title)
                    .accessibilityValue(accessibilityValue)
            }

            if showsAuthStatus {
                signInStatusIcon
            } else if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.Colors.onSurfaceMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(A11yLabel.remove(title))
                .accessibilityIdentifier(removeAccessibilityIdentifier ?? "")
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .chipSurface(fill.opacity(surfaceOpacity))
    }

    private var label: some View {
        HStack(spacing: 6) {
            if let service {
                ServiceAvatar(service: service, size: 20, shape: .roundedRect(4), monogramSize: 11)
            }
            Text(title)
                .font(Theme.Fonts.labelMd)
                .foregroundStyle(Theme.Colors.onSurface)
        }
    }

    private var signInStatus: AuthStatus? {
        guard let service else { return .signedOut }
        switch service.auth {
        case .checking, .signingIn:
            return .loading
        case .observed(let observation) where observation.value == .signedIn:
            return .signedIn
        case .authorized:
            return .signedIn
        case .notRequired:
            return nil
        case .unknown, .authorizationRequired, .notAuthorized, .observed, .unavailable:
            return .signedOut
        }
    }

    @ViewBuilder
    private var signInStatusIcon: some View {
        if let signInStatus {
            Group {
                switch signInStatus {
                case .signedIn:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.Colors.onSurfaceMuted)
                case .signedOut:
                    Image(systemName: "circle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.Colors.onSurfaceMuted)
                case .loading:
                    CellularAutomatonLoader(size: 14, tint: Theme.Colors.onSurfaceMuted.dynamic)
                }
            }
            .frame(width: 12, height: 12)
            .accessibilityHidden(true)
        }
    }

    private var accessibilityValue: String {
        guard let service else { return String(localized: "Sign-in unavailable") }
        switch service.auth {
        case .unknown:
            return String(localized: "Sign-in status unknown")
        case .checking:
            return String(localized: "Checking sign-in…")
        case .signingIn:
            return String(localized: "Signing in…")
        case .notRequired:
            return String(localized: "Sign-in not required")
        case .authorized:
            return service.detailCapabilities.authentication == .systemPermission
                ? String(localized: "Permission granted")
                : String(localized: "Authorized")
        case .authorizationRequired, .notAuthorized:
            return service.detailCapabilities.authentication == .systemPermission
                ? String(localized: "Permission not granted")
                : String(localized: "Not authorized")
        case .observed(let observation):
            switch observation.value {
            case .signedIn:
                return String(localized: "Signed in")
            case .signedOut:
                return String(localized: "Signed out")
            }
        case .unavailable:
            return String(localized: "Sign-in unavailable")
        }
    }
}
