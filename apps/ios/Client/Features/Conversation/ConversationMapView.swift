import MapKit
import SwiftUI

struct ConversationMapRoutes: MapContent {
    private struct Line: Identifiable {
        let id: String
        let route: MKRoute
        let isChosen: Bool
        let isEmphasized: Bool
        let showsBubble: Bool

        var midpoint: CLLocationCoordinate2D {
            route.polyline.points()[route.polyline.pointCount / 2].coordinate
        }
    }

    let outcomes: [Int: ConversationMapDirections.Outcome]
    var highlighted: Int?
    var chosen: [Int: Int] = [:]
    var showsTimes = true

    private var lines: [Line] {
        var alternatives: [Line] = []
        var picks: [Line] = []
        for leg in outcomes.keys.sorted() {
            let routes = outcomes[leg]?.routes ?? []
            guard !routes.isEmpty else { continue }
            let pick = min(chosen[leg] ?? 0, routes.count - 1)
            let isFocused = highlighted == nil || highlighted == leg
            if highlighted == leg {
                for (index, route) in routes.enumerated() where index != pick {
                    alternatives.append(Line(id: "\(leg).\(index)", route: route, isChosen: false, isEmphasized: true, showsBubble: true))
                }
            }
            picks.append(Line(id: "\(leg).\(pick)", route: routes[pick], isChosen: true, isEmphasized: isFocused, showsBubble: isFocused))
        }
        return alternatives + picks
    }

    var body: some MapContent {
        ForEach(lines) { line in
            let width: CGFloat = line.isChosen && line.isEmphasized && highlighted != nil ? 7 : 5
            let opacity = line.isEmphasized ? 1.0 : 0.45
            MapPolyline(line.route)
                .stroke(
                    (line.isChosen ? Theme.Colors.routeOutline : Theme.Colors.routeAlternateOutline).dynamic.opacity(opacity),
                    style: StrokeStyle(lineWidth: width + 3, lineCap: .round, lineJoin: .round)
                )
            MapPolyline(line.route)
                .stroke(
                    (line.isChosen ? Theme.Colors.route : Theme.Colors.routeAlternate).dynamic.opacity(opacity),
                    style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
                )
        }
        ForEach(showsTimes ? lines.filter(\.showsBubble) : []) { line in
            Annotation(coordinate: line.midpoint, anchor: .bottom) {
                ConversationMapTimeBubble(text: ConversationMapDirections.duration(line.route.expectedTravelTime), isChosen: line.isChosen)
            } label: {
                EmptyView()
            }
        }
    }
}

private struct ConversationMapTimeBubble: View {
    let text: String
    let isChosen: Bool

    var body: some View {
        Text(text)
            .font(Theme.Fonts.captionMd)
            .monospacedDigit()
            .foregroundStyle(isChosen ? Theme.Colors.onPrimary.dynamic : Theme.Colors.onSurface.dynamic)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xs)
            .background(isChosen ? Theme.Colors.route.dynamic : Theme.Colors.surface.dynamic, in: Capsule())
            .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
            .padding(.bottom, Theme.Spacing.xs)
            .accessibilityLabel("Travel time \(text)")
    }
}

struct ConversationMapView<Fallback: View>: View {
    let source: String
    let accessibilityIdentifier: String
    @ViewBuilder let fallback: () -> Fallback

    @State private var expanded = false
    @State private var outcomes: [Int: ConversationMapDirections.Outcome] = [:]
    @Namespace private var zoom

    var body: some View {
        if let map = ConversationMap.decode(source) {
            VStack(spacing: 0) {
                header(map)
                Divider()
                Button(action: { expand(map) }) {
                    Map(initialPosition: map.overview, interactionModes: []) {
                        ConversationMapRoutes(outcomes: outcomes)
                        ForEach(map.markers.indices, id: \.self) { index in
                            Marker(map.markers[index].title, coordinate: map.markers[index].coordinate)
                                .tint(Theme.Colors.primary.dynamic)
                        }
                    }
                    .mapStyle(.standard(pointsOfInterest: .excludingAll))
                    .allowsHitTesting(false)
                    .frame(height: 220)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open map, \(map.summary)")
                .accessibilityIdentifier("\(accessibilityIdentifier).map")
            }
            .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
            .conversationCardOutline()
            .matchedTransitionSource(id: source, in: zoom)
            .task(id: source) {
                guard !map.legs.isEmpty else { return }
                await ConversationMapDirections.outcomes(for: map, transports: map.defaultTransports) { outcomes = $0 }
            }
            .fullScreenCover(isPresented: $expanded) {
                ConversationMapScreen(map: map)
                    .navigationTransition(.zoom(sourceID: source, in: zoom))
            }
        } else {
            fallback()
                .task(id: source) {
                    Log.ui.error("ConversationMap.invalid bytes=\(source.utf8.count)")
                }
        }
    }

    private func header(_ map: ConversationMap) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            ConversationMapIcon(systemImage: map.legs.count == 1 ? map.legs[0].mode.systemImage : "map.fill")
            VStack(alignment: .leading, spacing: 2) {
                Text(map.summary)
                    .font(Theme.Fonts.labelMd)
                    .foregroundStyle(Theme.Colors.onSurface)
                    .lineLimit(1)
                Text(caption(map))
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                    .accessibilityIdentifier("\(accessibilityIdentifier).map.caption")
            }
            Spacer(minLength: Theme.Spacing.sm)
            ConversationMapGlassButton(systemImage: "arrow.up.left.and.arrow.down.right", label: "Open map", size: 44) {
                expand(map)
            }
            .accessibilityIdentifier("\(accessibilityIdentifier).map.expand")
        }
        .frame(minHeight: Theme.Size.minimumTouchTarget)
        .padding(.leading, Theme.Spacing.md)
        .padding(.trailing, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.sm)
    }

    private func caption(_ map: ConversationMap) -> String {
        guard !map.legs.isEmpty else { return map.caption }
        guard outcomes.count == map.legs.count else { return "Finding route…" }
        let routes = outcomes.keys.sorted().compactMap { outcomes[$0]?.routes.first }
        if routes.isEmpty { return map.legs.count == 1 ? "Route unavailable" : "Routes unavailable" }
        if map.legs.count == 1 { return ConversationMapDirections.describe(routes[0], transport: map.legs[0].mode) }
        let unavailable = map.legs.count - routes.count
        let total = "\(map.legs.count) routes · \(ConversationMapDirections.distance(routes.map(\.distance).reduce(0, +))) · \(ConversationMapDirections.duration(routes.map(\.expectedTravelTime).reduce(0, +)))"
        return unavailable == 0 ? total : "\(total) · \(unavailable) unavailable"
    }

    private func expand(_ map: ConversationMap) {
        expanded = true
        Log.ui.info("ConversationMap.expand markers=\(map.markers.count) routes=\(map.legs.count)")
    }
}

struct ConversationMapIcon: View {
    var systemImage = "map.fill"

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Theme.Colors.primary.dynamic)
            .frame(width: 34, height: 34)
            .background(
                Theme.Colors.primary.dynamic.opacity(0.12),
                in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}

struct ConversationMapGlassButton: View {
    let systemImage: String
    let label: String
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(Theme.Colors.onSurface)
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel(label)
    }
}
