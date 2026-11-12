import MapKit
import SwiftUI

struct ConversationMapScreen: View {
    typealias Transport = ConversationMap.Route.Transport

    enum Selection: Hashable {
        case place(Int)
        case route(Int)
    }

    private static let collapsedHeight: CGFloat = 104
    private static let collapsed = PresentationDetent.height(collapsedHeight)
    private static let expanded = PresentationDetent.fraction(0.45)
    private static let place = PresentationDetent.height(230)

    let map: ConversationMap

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position: MapCameraPosition
    @State private var selection: Selection?
    @State private var visibleSpan: MKCoordinateSpan?
    @State private var outcomes: [Int: ConversationMapDirections.Outcome]
    @State private var transports: [Int: Transport]
    @State private var chosen: [Int: Int] = [:]
    @State private var detent = collapsed
    @State private var showsSheet = true

    init(map: ConversationMap) {
        self.map = map
        _position = State(initialValue: map.overview)
        _transports = State(initialValue: map.defaultTransports)
        _outcomes = State(initialValue: ConversationMapDirections.cached(for: map, transports: map.defaultTransports))
    }

    private var motion: Animation? { reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.1) }

    private var isPlaceSelected: Bool {
        if case .place = selection { return true }
        return false
    }

    private var highlightedRoute: Int? {
        if case .route(let index) = selection { return index }
        return nil
    }

    private var selectedPlace: Binding<Int?> {
        Binding {
            if case .place(let index) = selection { return index }
            return nil
        } set: { index in
            if let index {
                select(.place(index))
            } else if case .place = selection {
                select(nil)
            }
        }
    }

    var body: some View {
        Map(position: $position, selection: selectedPlace) {
            ConversationMapRoutes(outcomes: outcomes, highlighted: highlightedRoute, chosen: chosen, showsTimes: !isPlaceSelected)
            ForEach(map.markers.indices, id: \.self) { index in
                Marker(map.markers[index].title, coordinate: map.markers[index].coordinate)
                    .tint(Theme.Colors.primary.dynamic)
                    .tag(index)
            }
        }
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .safeAreaPadding(.bottom, Self.collapsedHeight)
        .onMapCameraChange(frequency: .onEnd) { context in
            visibleSpan = context.region.span
        }
        .task(id: transports) { await refreshRoutes() }
        .safeAreaInset(edge: .top, spacing: 0) { topBar }
        .sheet(isPresented: $showsSheet) {
            sheetContent
                .animation(motion, value: selection)
                .presentationDetents([Self.collapsed, Self.place, Self.expanded, .large], selection: $detent)
                .presentationBackgroundInteraction(.enabled(upThrough: Self.expanded))
                .presentationContentInteraction(.resizes)
                .presentationDragIndicator(.visible)
                .interactiveDismissDisabled()
        }
    }

    @ViewBuilder
    private var sheetContent: some View {
        switch selection {
        case .place(let index):
            ConversationMapPlaceSheet(marker: map.markers[index], onClose: { select(nil) })
                .id(selection)
                .transition(.opacity)
        case .route(let index):
            ConversationMapRouteSheet(
                title: map.title(of: map.legs[index]),
                transport: transportBinding(index),
                chosen: chosenBinding(index),
                outcome: outcomes[index],
                onDirections: { ConversationMapDirections.openInMaps(map.legs[index], transport: transports[index] ?? map.legs[index].mode, in: map) },
                onClose: { select(nil) }
            )
            .id(selection)
            .transition(.opacity)
        case nil:
            overview
                .transition(.opacity)
        }
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ConversationMapSheetHeader(
                    systemImage: map.legs.count == 1 ? (transports[0] ?? map.legs[0].mode).systemImage : "map.fill",
                    title: map.summary,
                    subtitle: map.legs.count == 1 ? routeSummary(0) : map.caption,
                    accessibilityIdentifier: "conversation.map.overview",
                    onClose: nil
                )
                ForEach(map.legs.indices, id: \.self) { index in
                    Divider().padding(.leading, Theme.Spacing.lg)
                    row(
                        systemImage: (transports[index] ?? map.legs[index].mode).systemImage,
                        title: map.title(of: map.legs[index]),
                        subtitle: routeSummary(index),
                        target: .route(index)
                    )
                    .accessibilityIdentifier("conversation.map.route.\(index)")
                }
                ForEach(map.markers.indices, id: \.self) { index in
                    Divider().padding(.leading, Theme.Spacing.lg)
                    row(systemImage: "mappin", title: map.markers[index].title, subtitle: map.markers[index].detail?.address, target: .place(index))
                        .accessibilityIdentifier("conversation.map.place.\(index)")
                }
            }
            .padding(.top, Theme.Spacing.sm)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func row(systemImage: String, title: String, subtitle: String?, target: Selection) -> some View {
        Button {
            select(target)
        } label: {
            HStack(spacing: Theme.Spacing.md) {
                ConversationMapIcon(systemImage: systemImage)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Theme.Fonts.labelMd)
                        .foregroundStyle(Theme.Colors.onSurface)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.Colors.onSurfaceMuted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: Theme.Spacing.sm)
                Image(systemName: "chevron.right")
                    .font(Theme.Icons.sm)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.sm)
            .frame(minHeight: Theme.Size.minimumTouchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func routeSummary(_ index: Int) -> String {
        let transport = transports[index] ?? map.legs[index].mode
        switch outcomes[index] {
        case .found(let routes):
            let pick = routes[min(chosen[index] ?? 0, routes.count - 1)]
            return ConversationMapDirections.describe(pick, transport: transport)
        case .unavailable: return "Route unavailable"
        case nil: return "Finding route…"
        }
    }

    private func transportBinding(_ index: Int) -> Binding<Transport> {
        Binding {
            transports[index] ?? map.legs[index].mode
        } set: { transport in
            guard transports[index] != transport else { return }
            transports[index] = transport
            chosen[index] = 0
            Log.ui.info("ConversationMap.transport route=\(index) transport=\(transport.rawValue)")
        }
    }

    private func chosenBinding(_ index: Int) -> Binding<Int> {
        Binding {
            chosen[index] ?? 0
        } set: { option in
            withAnimation(motion) { chosen[index] = option }
            Log.ui.info("ConversationMap.option route=\(index) option=\(option)")
        }
    }

    private var topBar: some View {
        HStack(spacing: Theme.Spacing.sm) {
            ConversationMapGlassButton(systemImage: "xmark", label: "Close map", size: 44) { dismiss() }
                .accessibilityIdentifier("conversation.map.close")
            Spacer()
            if map.markers.count > 1 {
                ConversationMapGlassButton(systemImage: "arrow.down.right.and.arrow.up.left", label: "Show all places", size: 44) {
                    select(nil)
                    withAnimation(motion) { position = map.overview }
                    Log.ui.info("ConversationMap.showAll markers=\(map.markers.count)")
                }
                .accessibilityIdentifier("conversation.map.showAll")
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.top, Theme.Spacing.sm)
    }

    private func refreshRoutes() async {
        guard !map.legs.isEmpty else { return }
        outcomes = ConversationMapDirections.cached(for: map, transports: transports)
        await ConversationMapDirections.outcomes(for: map, transports: transports) { outcomes = $0 }
        guard !Task.isCancelled, let index = highlightedRoute else { return }
        withAnimation(motion) { position = routeCamera(index) }
    }

    private func select(_ target: Selection?) {
        guard target != selection else { return }
        withAnimation(motion) {
            selection = target
            switch target {
            case .place: detent = Self.place
            case .route: detent = Self.expanded
            case nil: detent = Self.collapsed
            }
            switch target {
            case .place(let index): position = region(focusing: map.markers[index])
            case .route(let index): position = routeCamera(index)
            case nil: break
            }
        }
        switch target {
        case .place(let index): Log.ui.info("ConversationMap.select place=\(index) detail=\(map.markers[index].detail != nil) placeID=\(map.markers[index].placeID != nil)")
        case .route(let index): Log.ui.info("ConversationMap.select route=\(index) transport=\((transports[index] ?? map.legs[index].mode).rawValue)")
        case nil: Log.ui.info("ConversationMap.select none")
        }
    }

    private func routeCamera(_ index: Int) -> MapCameraPosition {
        .rect(ConversationMap.padded(map.bounds(of: map.legs[index], outcome: outcomes[index]), bottom: 0.9))
    }

    private func region(focusing marker: ConversationMap.Marker) -> MapCameraPosition {
        let span = visibleSpan.map { MKCoordinateSpan(latitudeDelta: min($0.latitudeDelta, 0.05), longitudeDelta: min($0.longitudeDelta, 0.05)) }
            ?? ConversationMap.placeSpan
        let center = CLLocationCoordinate2D(latitude: marker.latitude - span.latitudeDelta * 0.15, longitude: marker.longitude)
        return .region(MKCoordinateRegion(center: center, span: span))
    }
}

private struct ConversationMapSheetHeader: View {
    let systemImage: String
    let title: String
    let subtitle: String?
    let accessibilityIdentifier: String
    let onClose: (() -> Void)?

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            ConversationMapIcon(systemImage: systemImage)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Fonts.title)
                    .foregroundStyle(Theme.Colors.onSurface)
                    .lineLimit(2)
                    .accessibilityIdentifier("\(accessibilityIdentifier).title")
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.onSurfaceMuted)
                        .lineLimit(2)
                        .contentTransition(.opacity)
                        .accessibilityIdentifier("\(accessibilityIdentifier).subtitle")
                }
            }
            Spacer(minLength: Theme.Spacing.sm)
            if let onClose {
                ConversationMapGlassButton(systemImage: "xmark", label: "Close details", size: 36, action: onClose)
                    .accessibilityIdentifier("\(accessibilityIdentifier).close")
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
        .frame(minHeight: Theme.Size.minimumTouchTarget)
    }
}

private struct ConversationMapRouteSheet: View {
    typealias Transport = ConversationMap.Route.Transport

    let title: String
    @Binding var transport: Transport
    @Binding var chosen: Int
    let outcome: ConversationMapDirections.Outcome?
    let onDirections: () -> Void
    let onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                ConversationMapSheetHeader(
                    systemImage: transport.systemImage,
                    title: title,
                    subtitle: subtitle,
                    accessibilityIdentifier: "conversation.map.routeDetail",
                    onClose: onClose
                )
                Picker("Travel mode", selection: $transport) {
                    ForEach(Transport.allCases, id: \.self) { mode in
                        Image(systemName: mode.systemImage)
                            .accessibilityLabel(mode.label)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, Theme.Spacing.lg)
                .accessibilityIdentifier("conversation.map.routeDetail.mode")
                content
            }
            .padding(.top, Theme.Spacing.sm)
            .padding(.bottom, Theme.Spacing.lg)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var subtitle: String {
        switch outcome {
        case .found(let routes): ConversationMapDirections.describe(routes[min(chosen, routes.count - 1)], transport: transport)
        case .unavailable: "Route unavailable"
        case nil: "Finding route…"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch outcome {
        case .found(let routes):
            let pick = min(chosen, routes.count - 1)
            VStack(spacing: Theme.Spacing.sm) {
                ForEach(routes.indices, id: \.self) { index in
                    option(routes[index], index: index, isChosen: index == pick)
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
            directionsButton
        case .unavailable:
            Text("No \(transport.label.lowercased()) route found between these places.")
                .font(Theme.Fonts.bodySm)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                .padding(.horizontal, Theme.Spacing.lg)
                .accessibilityIdentifier("conversation.map.routeDetail.unavailable")
            directionsButton
        case nil:
            HStack(spacing: Theme.Spacing.sm) {
                ProgressView()
                Text("Finding route…")
            }
            .font(Theme.Fonts.bodySm)
            .foregroundStyle(Theme.Colors.onSurfaceMuted)
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    private var directionsButton: some View {
        Button(action: onDirections) {
            Label("Directions in Maps", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
        }
        .buttonStyle(OxChipButton())
        .padding(.horizontal, Theme.Spacing.lg)
        .accessibilityIdentifier("conversation.map.routeDetail.directions")
    }

    private func option(_ route: MKRoute, index: Int, isChosen: Bool) -> some View {
        Button {
            chosen = index
        } label: {
            HStack(spacing: Theme.Spacing.md) {
                Text(ConversationMapDirections.duration(route.expectedTravelTime))
                    .font(Theme.Fonts.labelMd)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Colors.onSurface)
                Text([ConversationMapDirections.arrival(route), ConversationMapDirections.distance(route.distance), route.name].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .frame(minHeight: Theme.Size.minimumTouchTarget)
            .background(Theme.Colors.surfaceSunken, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .strokeBorder(isChosen ? Theme.Colors.route.dynamic : .clear, lineWidth: 2)
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
        .accessibilityIdentifier("conversation.map.routeDetail.option.\(index)")
    }
}

private struct ConversationMapPlaceSheet: View {
    let marker: ConversationMap.Marker
    let onClose: () -> Void

    @State private var appleItem: MKMapItem?

    private var website: URL? { marker.detail?.website ?? appleItem?.url }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                ConversationMapSheetHeader(
                    systemImage: "mappin",
                    title: marker.title,
                    subtitle: marker.detail?.address ?? appleItem?.address?.shortAddress,
                    accessibilityIdentifier: "conversation.map.detail",
                    onClose: onClose
                )
                if let description = marker.detail?.description {
                    Text(description)
                        .font(Theme.Fonts.bodySm)
                        .foregroundStyle(Theme.Colors.onSurface)
                        .textSelection(.enabled)
                        .padding(.horizontal, Theme.Spacing.lg)
                        .accessibilityIdentifier("conversation.map.detail.description")
                }
                ScrollView(.horizontal) {
                    HStack(spacing: Theme.Spacing.sm) { actions }
                        .padding(.horizontal, Theme.Spacing.lg)
                }
                .scrollIndicators(.hidden)
            }
            .padding(.top, Theme.Spacing.sm)
            .padding(.bottom, Theme.Spacing.lg)
        }
        .scrollBounceBehavior(.basedOnSize)
        .task(id: marker.placeID) { appleItem = await ConversationMapPlaces.item(for: marker) }
    }

    @ViewBuilder
    private var actions: some View {
        Button {
            ConversationMapPlaces.openInMaps(marker, item: appleItem)
        } label: {
            Label("Open in Maps", systemImage: "map")
        }
        .buttonStyle(OxChipButton())
        .accessibilityIdentifier("conversation.map.detail.openInMaps")
        if let website {
            Link(destination: website) {
                Label("Website", systemImage: "safari")
            }
            .buttonStyle(OxChipButton(filled: false))
            .accessibilityIdentifier("conversation.map.detail.website")
        }
    }
}
