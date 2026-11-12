import MapKit
import SwiftUI

struct ConversationMap: Decodable {
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
    }

    struct Route: Decodable {
        enum Transport: String, Decodable, CaseIterable, Hashable {
            case automobile
            case walking
            case cycling

            var directionsType: MKDirectionsTransportType {
                switch self {
                case .automobile: .automobile
                case .walking: .walking
                case .cycling: .cycling
                }
            }

            var launchMode: String {
                switch self {
                case .automobile: MKLaunchOptionsDirectionsModeDriving
                case .walking: MKLaunchOptionsDirectionsModeWalking
                case .cycling: MKLaunchOptionsDirectionsModeCycling
                }
            }

            var systemImage: String {
                switch self {
                case .automobile: "car.fill"
                case .walking: "figure.walk"
                case .cycling: "bicycle"
                }
            }

            var noun: String {
                switch self {
                case .automobile: "drive"
                case .walking: "walk"
                case .cycling: "ride"
                }
            }

            var label: String {
                switch self {
                case .automobile: "Drive"
                case .walking: "Walk"
                case .cycling: "Cycle"
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

    var defaultTransports: [Int: Route.Transport] {
        Dictionary(uniqueKeysWithValues: legs.enumerated().map { ($0.offset, $0.element.mode) })
    }

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
        let found = outcome?.routes ?? []
        guard !found.isEmpty else { return [markers[route.from].coordinate, markers[route.to].coordinate].boundingMapRect }
        return found.map(\.polyline.boundingMapRect).reduce(MKMapRect.null) { $0.union($1) }
    }

    static func padded(_ rect: MKMapRect, bottom: Double) -> MKMapRect {
        let inset = max(rect.width, rect.height, 2_000) * 0.3
        return MKMapRect(
            x: rect.minX - inset,
            y: rect.minY - inset,
            width: rect.width + inset * 2,
            height: rect.height + inset * 2 + (rect.height + inset * 2) * bottom
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

extension Array where Element == CLLocationCoordinate2D {
    var boundingMapRect: MKMapRect {
        map { MKMapRect(origin: MKMapPoint($0), size: MKMapSize(width: 0, height: 0)) }
            .reduce(MKMapRect.null) { $0.union($1) }
    }
}

@MainActor
enum ConversationMapDirections {
    typealias Transport = ConversationMap.Route.Transport

    enum Outcome {
        case found([MKRoute])
        case unavailable

        var routes: [MKRoute] {
            if case .found(let routes) = self { return routes }
            return []
        }
    }

    private struct Key: Hashable {
        let from: [Double]
        let to: [Double]
        let transport: Transport
    }

    private static var found: [Key: [MKRoute]] = [:]
    private static var pending: [Key: Task<Outcome, Never>] = [:]

    static func outcomes(for map: ConversationMap, transports: [Int: Transport], update: ([Int: Outcome]) -> Void) async {
        var outcomes = cached(for: map, transports: transports)
        for index in map.legs.indices where outcomes[index] == nil {
            outcomes[index] = await resolve(map.legs[index], transport: transports[index] ?? map.legs[index].mode, in: map)
            guard !Task.isCancelled else { return }
            update(outcomes)
        }
        update(outcomes)
    }

    static func cached(for map: ConversationMap, transports: [Int: Transport]) -> [Int: Outcome] {
        var outcomes: [Int: Outcome] = [:]
        for (index, route) in map.legs.enumerated() {
            if let cached = found[key(route, transport: transports[index] ?? route.mode, in: map)] { outcomes[index] = .found(cached) }
        }
        return outcomes
    }

    static func openInMaps(_ route: ConversationMap.Route, transport: Transport, in map: ConversationMap) {
        let opened = MKMapItem.openMaps(
            with: [map.markers[route.from].mapItem, map.markers[route.to].mapItem],
            launchOptions: [MKLaunchOptionsDirectionsModeKey: transport.launchMode]
        )
        Log.ui.info("ConversationMap.directions opened=\(opened) transport=\(transport.rawValue)")
    }

    static func describe(_ route: MKRoute, transport: Transport) -> String {
        "\(distance(route.distance)) · \(duration(route.expectedTravelTime)) \(transport.noun)"
    }

    static func distance(_ meters: CLLocationDistance) -> String {
        Measurement(value: meters, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road))
    }

    static func duration(_ seconds: TimeInterval) -> String {
        Duration.seconds(max(seconds, 60)).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    static func arrival(_ route: MKRoute) -> String {
        Date.now.addingTimeInterval(route.expectedTravelTime).formatted(date: .omitted, time: .shortened)
    }

    private static func key(_ route: ConversationMap.Route, transport: Transport, in map: ConversationMap) -> Key {
        let origin = map.markers[route.from], destination = map.markers[route.to]
        return Key(from: [origin.latitude, origin.longitude], to: [destination.latitude, destination.longitude], transport: transport)
    }

    private static func resolve(_ route: ConversationMap.Route, transport: Transport, in map: ConversationMap) async -> Outcome {
        let key = key(route, transport: transport, in: map)
        if let cached = found[key] { return .found(cached) }
        if let task = pending[key] { return await task.value }
        let request = MKDirections.Request()
        request.source = map.markers[route.from].mapItem
        request.destination = map.markers[route.to].mapItem
        request.transportType = transport.directionsType
        request.requestsAlternateRoutes = true
        let task = Task { await calculate(request, transport: transport) }
        pending[key] = task
        let outcome = await task.value
        pending[key] = nil
        if case .found(let calculated) = outcome { found[key] = calculated }
        return outcome
    }

    private static func calculate(_ request: MKDirections.Request, transport: Transport) async -> Outcome {
        let started = ContinuousClock.now
        do {
            let response = try await MKDirections(request: request).calculate()
            let elapsed = (ContinuousClock.now - started).components.seconds
            guard let best = response.routes.first else {
                Log.ui.error("ConversationMap.route empty transport=\(transport.rawValue) seconds=\(elapsed)")
                return .unavailable
            }
            Log.ui.info("ConversationMap.route found transport=\(transport.rawValue) options=\(response.routes.count) meters=\(Int(best.distance)) travelSeconds=\(Int(best.expectedTravelTime)) steps=\(best.steps.count) advisories=\(best.advisoryNotices.count) seconds=\(elapsed)")
            return .found(response.routes)
        } catch {
            let nsError = error as NSError
            Log.ui.error("ConversationMap.route failed transport=\(transport.rawValue) domain=\(nsError.domain) code=\(nsError.code)")
            return .unavailable
        }
    }
}

@MainActor
enum ConversationMapPlaces {
    private static var found: [String: MKMapItem] = [:]

    static func item(for marker: ConversationMap.Marker) async -> MKMapItem? {
        guard let placeID = marker.placeID, let identifier = MKMapItem.Identifier(rawValue: placeID) else { return nil }
        if let cached = found[placeID] { return cached }
        do {
            let item = try await MKMapItemRequest(mapItemIdentifier: identifier).mapItem
            found[placeID] = item
            Log.ui.info("ConversationMap.place found phone=\(item.phoneNumber != nil) url=\(item.url != nil)")
            return item
        } catch {
            let nsError = error as NSError
            Log.ui.error("ConversationMap.place failed domain=\(nsError.domain) code=\(nsError.code)")
            return nil
        }
    }

    static func openInMaps(_ marker: ConversationMap.Marker, item: MKMapItem?) {
        let opened = (item ?? marker.mapItem).openInMaps()
        Log.ui.info("ConversationMap.openInMaps opened=\(opened) apple=\(item != nil)")
    }
}
