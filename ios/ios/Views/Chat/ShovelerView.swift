import SwiftUI

struct ShovelerView: View {
    let shoveler: Shoveler
    let accessibilityPrefix: String
    let onOpenArtifact: (Artifact, String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            ShovelerLayout(spacing: Theme.Spacing.md) {
                ForEach(Array(shoveler.cards.enumerated()), id: \.offset) { index, card in
                    ShovelerCardContainer(
                        card: card,
                        sourceID: "\(accessibilityPrefix).card.\(index):\(card.artifact?.id ?? "none")",
                        onOpenArtifact: onOpenArtifact
                    )
                        .accessibilityIdentifier("\(accessibilityPrefix).card.\(index)")
                }
            }
            .scrollTargetLayout()
            .padding(.bottom, 1)
        }
        .scrollTargetBehavior(.viewAligned)
        .excludesCompactPageSwitch()
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier(accessibilityPrefix)
    }
}

private struct ShovelerLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let sizes = cardSizes(subviews)
        return CGSize(
            width: sizes.map(\.width).reduce(0, +) + spacing * CGFloat(max(0, sizes.count - 1)),
            height: sizes.map(\.height).max() ?? 0
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let sizes = cardSizes(subviews)
        var x = bounds.minX
        for (subview, size) in zip(subviews, sizes) {
            subview.place(
                at: CGPoint(x: x, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: size.width, height: bounds.height)
            )
            x += size.width + spacing
        }
    }

    private func cardSizes(_ subviews: Subviews) -> [CGSize] {
        subviews.map { subview in
            let width = min(max(subview.sizeThatFits(.unspecified).width, 160), 280)
            let height = subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
            return CGSize(width: width, height: height)
        }
    }
}

private struct ShovelerCardContainer: View {
    let card: ShovelerCard
    let sourceID: String
    let onOpenArtifact: (Artifact, String) -> Void

    @ViewBuilder
    var body: some View {
        if let artifact = card.artifact, artifact.exists {
            Button { onOpenArtifact(artifact, sourceID) } label: {
                ShovelerCardView(card: card)
                    .artifactPreviewTransitionSource(artifact, sourceID: sourceID)
            }
            .buttonStyle(.plain)
            .accessibilityHint(String(format: L10n.string("Opens %@"), artifact.userFacingName))
        } else {
            ShovelerCardView(card: card)
        }
    }
}

private struct ShovelerCardView: View {
    let card: ShovelerCard

    private var imageURL: URL? {
        card.image.flatMap(URL.init(string:))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let imageURL {
                ShovelerImage(url: imageURL)
                    .overlay(alignment: .topLeading) {
                        if let badge = card.badge {
                            badgeView(badge)
                                .padding(Theme.Spacing.sm)
                        }
                    }
            }
            if card.title != nil || card.description != nil || (imageURL == nil && card.badge != nil) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    if imageURL == nil, let badge = card.badge {
                        badgeView(badge)
                    }
                    if let title = card.title {
                        Text(title)
                            .font(Theme.Fonts.title)
                            .foregroundStyle(Theme.Colors.onSurface)
                            .lineLimit(2)
                    }
                    if let description = card.description {
                        Text(description)
                            .font(Theme.Fonts.bodySm)
                            .foregroundStyle(Theme.Colors.onSurfaceMuted)
                            .lineLimit(3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Spacing.md)
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.Colors.background)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func badgeView(_ badge: String) -> some View {
        Text(badge)
            .font(Theme.Fonts.captionMd)
            .foregroundStyle(Theme.Colors.onSurface)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xs)
            .background(.regularMaterial, in: Capsule())
    }
}

private struct ShovelerImage: View {
    let url: URL

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: Theme.Animation.standard))) { phase in
            switch phase {
            case let .success(image):
                image
                    .resizable()
                    .scaledToFit()
                    .transition(.opacity)
            case .failure:
                Image(systemName: "photo")
                    .font(Theme.Icons.lg)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    .frame(width: 160)
            case .empty:
                CellularAutomatonLoader(size: 16, tint: Theme.Colors.onSurfaceMuted.dynamic)
                    .frame(width: 160)
            @unknown default:
                EmptyView()
                    .frame(width: 160)
            }
        }
        .frame(height: 160)
        .clipped()
        .accessibilityHidden(true)
    }
}
