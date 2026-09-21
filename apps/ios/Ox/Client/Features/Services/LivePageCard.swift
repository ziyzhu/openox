import SwiftUI
import WebKit

struct LivePageCardAnchorKey: PreferenceKey {
    static let defaultValue: [UUID: Anchor<CGRect>] = [:]

    static func reduce(value: inout [UUID: Anchor<CGRect>], nextValue: () -> [UUID: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

struct LivePageCard: View {
    enum Placeholder {
        case progress(String)
        case unavailable(String)
        case invitation(String)
    }

    let service: Service?
    let fallbackSystemImage: String
    let title: String
    let subtitle: String
    let page: WebPage?
    let inlinePageAnchorID: UUID?
    let isPresented: Bool
    let placeholder: Placeholder
    let activate: (() -> Void)?
    let expand: (() -> Void)?
    let cancel: (() -> Void)?
    let accessibilityIdentifier: String
    let expandAccessibilityIdentifier: String
    let cancelAccessibilityIdentifier: String

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .stroke(Theme.Colors.onSurfaceMuted.opacity(0.18), lineWidth: 1)
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.md) {
            identity
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Fonts.labelMd)
                    .foregroundStyle(Theme.Colors.onSurface)
                    .lineLimit(1)
                    .accessibilityIdentifier(accessibilityIdentifier)
                Text(subtitle)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    .lineLimit(2)
            }
            Spacer(minLength: Theme.Spacing.sm)
            actions
        }
        .frame(minHeight: Theme.Size.minimumTouchTarget)
        .padding(.leading, Theme.Spacing.md)
        .padding(.trailing, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.sm)
    }

    @ViewBuilder
    private var identity: some View {
        if let service {
            ServiceAvatar(service: service, size: 34, shape: .roundedRect(Theme.Radius.sm))
        } else {
            Image(systemName: fallbackSystemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.Colors.primary.dynamic)
                .frame(width: 34, height: 34)
                .background(
                    Theme.Colors.primary.dynamic.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                )
        }
    }

    @ViewBuilder
    private var actions: some View {
        if expand != nil || cancel != nil {
            HStack(spacing: Theme.Spacing.sm) {
                if let expand {
                    actionButton(
                        systemImage: "arrow.up.left.and.arrow.down.right",
                        accessibilityLabel: String(localized: "View live page"),
                        accessibilityIdentifier: expandAccessibilityIdentifier,
                        action: expand
                    )
                }
                if let cancel {
                    actionButton(
                        systemImage: "xmark",
                        accessibilityLabel: String(localized: "Cancel"),
                        accessibilityIdentifier: cancelAccessibilityIdentifier,
                        action: cancel
                    )
                }
            }
        }
    }

    private func actionButton(
        systemImage: String,
        accessibilityLabel: String,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(Theme.Colors.onSurface)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    @ViewBuilder
    private var content: some View {
        if let inlinePageAnchorID {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .anchorPreference(key: LivePageCardAnchorKey.self, value: .bounds) {
                    [inlinePageAnchorID: $0]
                }
        } else if let page, !isPresented {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    WebContentView(page: page)
                }
        } else {
            placeholderView
        }
    }

    @ViewBuilder
    private var placeholderView: some View {
        if let activate {
            Button(action: activate) {
                placeholderContent
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "View live page"))
        } else {
            placeholderContent
        }
    }

    private var placeholderContent: some View {
        VStack(spacing: Theme.Spacing.md) {
            switch placeholder {
            case .progress(let message):
                ProgressView()
                Text(message)
            case .unavailable(let message):
                Image(systemName: "safari.fill")
                    .font(.title2)
                Text(message)
            case .invitation(let message):
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.title2)
                Text(message)
            }
        }
        .font(Theme.Fonts.bodySm)
        .foregroundStyle(Theme.Colors.onSurfaceMuted)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .frame(height: 220)
        .padding(.horizontal, Theme.Spacing.xl)
    }
}
