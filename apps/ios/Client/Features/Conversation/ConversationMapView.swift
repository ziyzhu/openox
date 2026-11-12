import MapKit
import SwiftUI

private struct ConversationMap: Decodable {
    struct Marker: Decodable {
        struct Detail: Decodable {
            let title: String?
            let description: String?
            let address: String?
            let url: String?

            var website: URL? {
                guard let url, let parsed = URL(string: url), parsed.scheme == "https",
                      let host = parsed.host, !host.isEmpty,
                      parsed.user == nil, parsed.password == nil else { return nil }
                return parsed
            }

            var isValid: Bool {
                [title, description, address, url].allSatisfy { ($0?.count ?? 0) <= 2_000 }
            }
        }

        let latitude: Double
        let longitude: Double
        let label: String?
        let placeID: String?
        let detail: Detail?

        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }

        var title: String { detail?.title ?? label ?? "Place" }

        var isValid: Bool {
            latitude.isFinite && longitude.isFinite
                && (-90...90).contains(latitude) && (-180...180).contains(longitude)
                && (label?.count ?? 0) <= 200 && (placeID?.count ?? 0) <= 200
                && (detail?.isValid ?? true)
        }

        var mapItem: MKMapItem {
            let item = MKMapItem(location: CLLocation(latitude: latitude, longitude: longitude), address: nil)
            item.name = title
            return item
        }

        func openInMaps() {
            let opened = mapItem.openInMaps()
            Log.ui.info("ConversationMap.openInMaps opened=\(opened)")
        }
    }

    struct Route: Decodable {
        enum Transport: String, Decodable {
            case automobile
            case walking

            var directionsType: MKDirectionsTransportType {
                switch self {
                case .automobile: .automobile
                case .walking: .walking
                }
            }

            var launchMode: String {
                switch self {
                case .automobile: MKLaunchOptionsDirectionsModeDriving
                case .walking: MKLaunchOptionsDirectionsModeWalking
                }
            }

            var systemImage: String {
                switch self {
                case .automobile: "car.fill"
                case .walking: "figure.walk"
                }
            }

            var noun: String {
                switch self {
                case .automobile: "drive"
                case .walking: "walk"
                }
            }
        }

        let from: Int
        let to: Int
        private let transport: Transport?

        var mode: Transport { transport ?? .automobile }

        func isValid(markerCount: Int) -> Bool {
            from != to && (0..<markerCount).contains(from) && (0..<markerCount).contains(to)
        }
    }

    let markers: [Marker]
    private let routes: [Route]?

    static let placeSpan = MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
    static let maximumRoutes = 5

    var legs: [Route] { routes ?? [] }

    var summary: String {
        if legs.count == 1 { return title(of: legs[0]) }
        return markers.count == 1 ? markers[0].title : "\(markers.count) places"
    }

    var caption: String {
        if markers.count == 1 { return markers[0].detail?.address ?? "Map" }
        return markers.map(\.title).joined(separator: " · ")
    }

    var overview: MapCameraPosition {
        guard markers.count > 1 else { return .region(MKCoordinateRegion(center: markers[0].coordinate, span: Self.placeSpan)) }
        return .rect(Self.padded(markers.map(\.coordinate).boundingMapRect, bottom: 0.4))
    }

    func title(of route: Route) -> String {
        "\(markers[route.from].title) → \(markers[route.to].title)"
    }

    func bounds(of route: Route, outcome: ConversationMapDirections.Outcome?) -> MKMapRect {
        if case .found(let found) = outcome { return found.polyline.boundingMapRect }
        return [markers[route.from].coordinate, markers[route.to].coordinate].boundingMapRect
    }

    static func padded(_ rect: MKMapRect, bottom: Double) -> MKMapRect {
        let inset = max(rect.width, rect.height, 2_000) * 0.3
        return MKMapRect(
            x: rect.minX - inset,
            y: rect.minY - inset,
            width: rect.width + inset * 2,
            height: rect.height + inset * 2 + rect.height * bottom
        )
    }

    static func decode(_ source: String) -> Self? {
        guard source.utf8.count <= 65_536,
              let map = try? JSONDecoder().decode(Self.self, from: Data(source.utf8)),
              (1...50).contains(map.markers.count), map.markers.allSatisfy(\.isValid),
              map.legs.count <= maximumRoutes,
              map.legs.allSatisfy({ $0.isValid(markerCount: map.markers.count) }) else { return nil }
        return map
    }
}

private extension Array where Element == CLLocationCoordinate2D {
    var boundingMapRect: MKMapRect {
        map { MKMapRect(origin: MKMapPoint($0), size: MKMapSize(width: 0, height: 0)) }
            .reduce(MKMapRect.null) { $0.union($1) }
    }
}

@MainActor
private enum ConversationMapDirections {
    enum Outcome {
        case found(MKRoute)
        case unavailable
    }

    private struct Key: Hashable {
        let from: [Double]
        let to: [Double]
        let transport: ConversationMap.Route.Transport
    }

    private static var found: [Key: MKRoute] = [:]
    private static var pending: [Key: Task<Outcome, Never>] = [:]

    static func outcomes(for map: ConversationMap, update: ([Int: Outcome]) -> Void) async {
        var outcomes: [Int: Outcome] = [:]
        for index in map.legs.indices {
            outcomes[index] = await resolve(map.legs[index], in: map)
            guard !Task.isCancelled else { return }
            update(outcomes)
        }
    }

    static func cached(for map: ConversationMap) -> [Int: Outcome] {
        var outcomes: [Int: Outcome] = [:]
        for (index, route) in map.legs.enumerated() {
            if let cached = found[key(route, in: map)] { outcomes[index] = .found(cached) }
        }
        return outcomes
    }

    static func openInMaps(_ route: ConversationMap.Route, in map: ConversationMap) {
        let opened = MKMapItem.openMaps(
            with: [map.markers[route.from].mapItem, map.markers[route.to].mapItem],
            launchOptions: [MKLaunchOptionsDirectionsModeKey: route.mode.launchMode]
        )
        Log.ui.info("ConversationMap.directions opened=\(opened) transport=\(route.mode.rawValue)")
    }

    static func describe(_ route: MKRoute, transport: ConversationMap.Route.Transport) -> String {
        "\(distance(route.distance)) · \(duration(route.expectedTravelTime)) \(transport.noun)"
    }

    static func distance(_ meters: CLLocationDistance) -> String {
        Measurement(value: meters, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road))
    }

    static func duration(_ seconds: TimeInterval) -> String {
        Duration.seconds(max(seconds, 60)).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    private static func key(_ route: ConversationMap.Route, in map: ConversationMap) -> Key {
        let origin = map.markers[route.from], destination = map.markers[route.to]
        return Key(from: [origin.latitude, origin.longitude], to: [destination.latitude, destination.longitude], transport: route.mode)
    }

    private static func resolve(_ route: ConversationMap.Route, in map: ConversationMap) async -> Outcome {
        let key = key(route, in: map)
        if let cached = found[key] { return .found(cached) }
        if let task = pending[key] { return await task.value }
        let request = MKDirections.Request()
        request.source = map.markers[route.from].mapItem
        request.destination = map.markers[route.to].mapItem
        request.transportType = route.mode.directionsType
        let task = Task { await calculate(request, transport: route.mode) }
        pending[key] = task
        let outcome = await task.value
        pending[key] = nil
        if case .found(let calculated) = outcome { found[key] = calculated }
        return outcome
    }

    private static func calculate(_ request: MKDirections.Request, transport: ConversationMap.Route.Transport) async -> Outcome {
        let started = ContinuousClock.now
        do {
            let response = try await MKDirections(request: request).calculate()
            let elapsed = (ContinuousClock.now - started).components.seconds
            guard let route = response.routes.first else {
                Log.ui.error("ConversationMap.route empty transport=\(transport.rawValue) seconds=\(elapsed)")
                return .unavailable
            }
            Log.ui.info("ConversationMap.route found transport=\(transport.rawValue) meters=\(Int(route.distance)) travelSeconds=\(Int(route.expectedTravelTime)) seconds=\(elapsed)")
            return .found(route)
        } catch {
            let nsError = error as NSError
            Log.ui.error("ConversationMap.route failed transport=\(transport.rawValue) domain=\(nsError.domain) code=\(nsError.code)")
            return .unavailable
        }
    }
}

private struct ConversationMapRoutes: MapContent {
    let map: ConversationMap
    let outcomes: [Int: ConversationMapDirections.Outcome]
    var highlighted: Int?

    var body: some MapContent {
        ForEach(map.legs.indices, id: \.self) { index in
            if case .found(let route) = outcomes[index] {
                MapPolyline(route.polyline)
                    .stroke(
                        Theme.Colors.primary.dynamic.opacity(highlighted == nil || highlighted == index ? 1 : 0.45),
                        style: StrokeStyle(lineWidth: highlighted == index ? 7 : 5, lineCap: .round, lineJoin: .round)
                    )
            }
        }
    }
}

struct ConversationMapView<Fallback: View>: View {
    let source: String
    let accessibilityIdentifier: String
    @ViewBuilder let fallback: () -> Fallback

    @State private var expanded = false
    @State private var outcomes: [Int: ConversationMapDirections.Outcome] = [:]

    var body: some View {
        if let map = ConversationMap.decode(source) {
            VStack(spacing: 0) {
                header(map)
                Divider()
                Button(action: { expand(map) }) {
                    Map(initialPosition: map.overview, interactionModes: []) {
                        ConversationMapRoutes(map: map, outcomes: outcomes)
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
            .task(id: source) {
                guard !map.legs.isEmpty else { return }
                await ConversationMapDirections.outcomes(for: map) { outcomes = $0 }
            }
            .fullScreenCover(isPresented: $expanded) {
                ConversationMapScreen(map: map)
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
        let routes = outcomes.values.compactMap { outcome -> MKRoute? in
            if case .found(let route) = outcome { return route }
            return nil
        }
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

private struct ConversationMapIcon: View {
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

private struct ConversationMapGlassButton: View {
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

private struct ConversationMapScreen: View {
    enum Selection: Hashable {
        case place(Int)
        case route(Int)
    }

    let map: ConversationMap

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position: MapCameraPosition
    @State private var selection: Selection?
    @State private var visibleSpan: MKCoordinateSpan?
    @State private var outcomes: [Int: ConversationMapDirections.Outcome]

    init(map: ConversationMap) {
        self.map = map
        _position = State(initialValue: map.overview)
        _outcomes = State(initialValue: ConversationMapDirections.cached(for: map))
    }

    private var motion: Animation? { reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.1) }

    private var selectedPlace: Binding<Int?> {
        Binding {
            if case .place(let index) = selection { return index }
            return nil
        } set: { index in
            selection = index.map(Selection.place)
        }
    }

    private var highlightedRoute: Int? {
        if case .route(let index) = selection { return index }
        return nil
    }

    var body: some View {
        Map(position: $position, selection: selectedPlace) {
            ConversationMapRoutes(map: map, outcomes: outcomes, highlighted: highlightedRoute)
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
        .onMapCameraChange(frequency: .onEnd) { context in
            visibleSpan = context.region.span
        }
        .onChange(of: selection) { _, selection in
            switch selection {
            case .place(let index):
                Log.ui.info("ConversationMap.select place=\(index) detail=\(map.markers[index].detail != nil)")
                focus(on: map.markers[index])
            case .route(let index):
                Log.ui.info("ConversationMap.select route=\(index) transport=\(map.legs[index].mode.rawValue)")
                withAnimation(motion) {
                    position = .rect(ConversationMap.padded(map.bounds(of: map.legs[index], outcome: outcomes[index]), bottom: 0.8))
                }
            case nil:
                break
            }
        }
        .task {
            guard !map.legs.isEmpty else { return }
            await ConversationMapDirections.outcomes(for: map) { outcomes = $0 }
        }
        .safeAreaInset(edge: .top, spacing: 0) { topBar }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Group {
                switch selection {
                case .place(let index):
                    ConversationMapPlaceCard(marker: map.markers[index], onClose: clearSelection)
                        .id(selection)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                case .route(let index):
                    ConversationMapRouteCard(
                        title: map.title(of: map.legs[index]),
                        transport: map.legs[index].mode,
                        outcome: outcomes[index],
                        onDirections: { ConversationMapDirections.openInMaps(map.legs[index], in: map) },
                        onClose: clearSelection
                    )
                    .id(selection)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                case nil:
                    if map.markers.count > 1 || !map.legs.isEmpty {
                        chipStrip
                            .transition(.opacity)
                    }
                }
            }
            .animation(motion, value: selection)
        }
    }

    private func clearSelection() {
        withAnimation(motion) { selection = nil }
    }

    private var topBar: some View {
        HStack(spacing: Theme.Spacing.sm) {
            ConversationMapGlassButton(systemImage: "xmark", label: "Close map", size: 44) { dismiss() }
                .accessibilityIdentifier("conversation.map.close")
            Spacer()
            if map.markers.count > 1 {
                ConversationMapGlassButton(systemImage: "arrow.down.right.and.arrow.up.left", label: "Show all places", size: 44) {
                    selection = nil
                    withAnimation(motion) { position = map.overview }
                    Log.ui.info("ConversationMap.showAll markers=\(map.markers.count)")
                }
                .accessibilityIdentifier("conversation.map.showAll")
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.top, Theme.Spacing.sm)
    }

    private var chipStrip: some View {
        ScrollView(.horizontal) {
            GlassEffectContainer {
                HStack(spacing: Theme.Spacing.sm) {
                    ForEach(map.legs.indices, id: \.self) { index in
                        chip(map.title(of: map.legs[index]), systemImage: map.legs[index].mode.systemImage, selection: .route(index))
                            .accessibilityIdentifier("conversation.map.route.\(index)")
                    }
                    ForEach(map.markers.indices, id: \.self) { index in
                        chip(map.markers[index].title, systemImage: "mappin", selection: .place(index))
                            .accessibilityIdentifier("conversation.map.place.\(index)")
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
            }
        }
        .scrollIndicators(.hidden)
        .padding(.bottom, Theme.Spacing.sm)
    }

    private func chip(_ title: String, systemImage: String, selection target: Selection) -> some View {
        Button {
            selection = target
        } label: {
            Label(title, systemImage: systemImage)
                .font(Theme.Fonts.labelMd)
                .foregroundStyle(Theme.Colors.onSurface)
                .lineLimit(1)
                .padding(.horizontal, Theme.Spacing.md)
                .frame(minHeight: Theme.Size.minimumTouchTarget)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
    }

    private func focus(on marker: ConversationMap.Marker) {
        let span = visibleSpan.map { MKCoordinateSpan(latitudeDelta: min($0.latitudeDelta, 0.05), longitudeDelta: min($0.longitudeDelta, 0.05)) }
            ?? ConversationMap.placeSpan
        let center = CLLocationCoordinate2D(latitude: marker.latitude - span.latitudeDelta * 0.2, longitude: marker.longitude)
        withAnimation(motion) {
            position = .region(MKCoordinateRegion(center: center, span: span))
        }
    }
}

private struct ConversationMapCard<Body: View, Actions: View>: View {
    let systemImage: String
    let title: String
    let subtitle: String?
    let accessibilityIdentifier: String
    let onClose: () -> Void
    @ViewBuilder let content: () -> Body
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Spacing.md) {
                ConversationMapIcon(systemImage: systemImage)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Theme.Fonts.title)
                        .foregroundStyle(Theme.Colors.onSurface)
                        .lineLimit(2)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("\(accessibilityIdentifier).title")
                    if let subtitle {
                        Text(subtitle)
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.Colors.onSurfaceMuted)
                            .lineLimit(2)
                            .textSelection(.enabled)
                            .contentTransition(.opacity)
                            .accessibilityIdentifier("\(accessibilityIdentifier).subtitle")
                    }
                }
                Spacer(minLength: Theme.Spacing.sm)
                ConversationMapGlassButton(systemImage: "xmark", label: "Close details", size: 36, action: onClose)
                    .accessibilityIdentifier("\(accessibilityIdentifier).close")
            }
            .padding(Theme.Spacing.md)
            content()
            HStack(spacing: Theme.Spacing.sm) { actions() }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.bottom, Theme.Spacing.sm)
        }
        .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous))
        .conversationCardOutline(cornerRadius: Theme.Radius.xl)
        .shadow(color: .black.opacity(0.12), radius: 16, y: 4)
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.bottom, Theme.Spacing.sm)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private struct ConversationMapPlaceCard: View {
    let marker: ConversationMap.Marker
    let onClose: () -> Void

    var body: some View {
        ConversationMapCard(
            systemImage: "mappin",
            title: marker.title,
            subtitle: marker.detail?.address,
            accessibilityIdentifier: "conversation.map.detail",
            onClose: onClose
        ) {
            if let description = marker.detail?.description {
                Divider()
                ScrollView {
                    Text(description)
                        .font(Theme.Fonts.bodySm)
                        .foregroundStyle(Theme.Colors.onSurface)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Theme.Spacing.md)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 140)
                .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            Button(action: marker.openInMaps) {
                Label("Open in Maps", systemImage: "map")
            }
            .buttonStyle(OxChipButton())
            .accessibilityIdentifier("conversation.map.detail.openInMaps")
            if let website = marker.detail?.website {
                Link(destination: website) {
                    Label("Website", systemImage: "safari")
                }
                .buttonStyle(OxChipButton(filled: false))
                .accessibilityIdentifier("conversation.map.detail.website")
            }
        }
    }
}

private struct ConversationMapRouteCard: View {
    let title: String
    let transport: ConversationMap.Route.Transport
    let outcome: ConversationMapDirections.Outcome?
    let onDirections: () -> Void
    let onClose: () -> Void

    private var subtitle: String {
        switch outcome {
        case .found(let route): ConversationMapDirections.describe(route, transport: transport)
        case .unavailable: "Route unavailable"
        case nil: "Finding route…"
        }
    }

    var body: some View {
        ConversationMapCard(
            systemImage: transport.systemImage,
            title: title,
            subtitle: subtitle,
            accessibilityIdentifier: "conversation.map.routeDetail",
            onClose: onClose
        ) {
            EmptyView()
        } actions: {
            Button(action: onDirections) {
                Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
            }
            .buttonStyle(OxChipButton())
            .accessibilityIdentifier("conversation.map.routeDetail.directions")
        }
    }
}
