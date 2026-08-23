import CoreLocation
import Foundation
import MapKit

@MainActor
final class MapProvider {
    static let shared = MapProvider()

    struct Place: Encodable {
        let id: String?
        let name: String?
        let category: String?
        let address: String?
        let city: String?
        let country: String?
        let countryCode: String?
        let latitude: Double
        let longitude: Double
        let distanceMeters: Double?
        let timezone: String?
        let phone: String?
        let url: String?
    }

    struct Route: Encodable {
        let destination: Place
        let transport: String
        let distanceMeters: Double
        let expectedTravelTimeSeconds: Double
        let expectedDepartureAt: String
        let expectedArrivalAt: String
    }

    struct OpenResult: Encodable {
        let opened: Bool
    }

    enum MapError: LocalizedError {
        case invalid(String)
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .invalid(let reason):
                return "Couldn't use Maps: \(reason)"
            case .unavailable(let reason):
                return "Maps is unavailable: \(reason)"
            }
        }
    }

    private init() {}

    func searchNearby(query: String, radiusMeters: Double, limit: Int) async throws -> [Place] {
        let query = try Self.query(query)
        let radius = min(max(radiusMeters, 100), 50_000)
        let limit = min(max(limit, 1), 20)
        let origin = try await LocationProvider.shared.currentFix()
        let request = MKLocalSearch.Request(
            naturalLanguageQuery: query,
            region: MKCoordinateRegion(
                center: origin.coordinate,
                latitudinalMeters: radius * 2,
                longitudinalMeters: radius * 2
            )
        )
        request.regionPriority = .required
        request.resultTypes = [.pointOfInterest, .address]
        do {
            let response = try await MKLocalSearch(request: request).start()
            let results = response.mapItems.compactMap { item -> Place? in
                let distance = origin.distance(from: item.location)
                guard distance <= radius else { return nil }
                return Self.place(item, distanceMeters: distance)
            }.prefix(limit)
            Log.agent.info("location.search query=\(query) radius=\(Int(radius)) results=\(results.count)")
            return Array(results)
        } catch {
            Log.agent.error("location.search failed query=\(query) \(error.localizedDescription)")
            throw MapError.unavailable(error.localizedDescription)
        }
    }

    func resolve(query: String, limit: Int) async throws -> [Place] {
        let query = try Self.query(query)
        let limit = min(max(limit, 1), 10)
        guard let request = MKGeocodingRequest(addressString: query) else {
            throw MapError.invalid("'query' isn't a valid address")
        }
        do {
            let results = try await request.mapItems.prefix(limit).map { Self.place($0) }
            Log.agent.info("location.resolve query=\(query) results=\(results.count)")
            return Array(results)
        } catch {
            Log.agent.error("location.resolve failed query=\(query) \(error.localizedDescription)")
            throw MapError.unavailable(error.localizedDescription)
        }
    }

    func route(destination: String, transport: String) async throws -> Route {
        let destination = try Self.query(destination)
        let origin = try await LocationProvider.shared.currentFix()
        let destinationItem = try await searchDestination(destination, near: origin.coordinate)
        let request = MKDirections.Request()
        request.source = MKMapItem(location: origin, address: nil)
        request.destination = destinationItem
        request.transportType = try Self.transportType(transport)
        let directions = MKDirections(request: request)
        do {
            let eta = try await directions.calculateETA()
            let result = Route(
                destination: Self.place(destinationItem),
                transport: Self.transportName(eta.transportType),
                distanceMeters: eta.distance.rounded(),
                expectedTravelTimeSeconds: eta.expectedTravelTime.rounded(),
                expectedDepartureAt: Self.timestamp(eta.expectedDepartureDate),
                expectedArrivalAt: Self.timestamp(eta.expectedArrivalDate)
            )
            Log.agent.info("location.route destination=\(destination) transport=\(result.transport) meters=\(Int(result.distanceMeters)) seconds=\(Int(result.expectedTravelTimeSeconds))")
            return result
        } catch {
            Log.agent.error("location.route failed destination=\(destination) transport=\(transport) \(error.localizedDescription)")
            throw MapError.unavailable(error.localizedDescription)
        }
    }

    func openInMaps(placeID: String, directionsMode: String?) async throws -> OpenResult {
        let placeID = placeID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !placeID.isEmpty, placeID.count <= 200,
              let identifier = MKMapItem.Identifier(rawValue: placeID) else {
            throw MapError.invalid("'placeID' must be a valid MapKit place identifier")
        }
        do {
            let item = try await MKMapItemRequest(mapItemIdentifier: identifier).mapItem
            var options: [String: Any]?
            if let directionsMode {
                options = [MKLaunchOptionsDirectionsModeKey: try Self.launchDirectionsMode(directionsMode)]
            }
            let opened = item.openInMaps(launchOptions: options)
            Log.agent.info("location.open placeID=\(placeID) directions=\(directionsMode ?? "none") opened=\(opened)")
            return OpenResult(opened: opened)
        } catch let error as MapError {
            throw error
        } catch {
            Log.agent.error("location.open failed placeID=\(placeID) \(error.localizedDescription)")
            throw MapError.unavailable(error.localizedDescription)
        }
    }

    private func searchDestination(_ query: String, near coordinate: CLLocationCoordinate2D) async throws -> MKMapItem {
        let request = MKLocalSearch.Request(
            naturalLanguageQuery: query,
            region: MKCoordinateRegion(
                center: coordinate,
                latitudinalMeters: 100_000,
                longitudinalMeters: 100_000
            )
        )
        request.regionPriority = .default
        request.resultTypes = [.pointOfInterest, .address, .physicalFeature]
        do {
            guard let item = try await MKLocalSearch(request: request).start().mapItems.first else {
                throw MapError.unavailable("no destination matched '\(query)'")
            }
            return item
        } catch let error as MapError {
            throw error
        } catch {
            throw MapError.unavailable(error.localizedDescription)
        }
    }

    private static func query(_ value: String) throws -> String {
        let query = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw MapError.invalid("'query' is required") }
        guard query.count <= 200 else { throw MapError.invalid("'query' must be at most 200 characters") }
        return query
    }

    private static func place(_ item: MKMapItem, distanceMeters: Double? = nil) -> Place {
        let address = item.addressRepresentations
        return Place(
            id: item.identifier?.rawValue,
            name: item.name,
            category: item.pointOfInterestCategory?.rawValue,
            address: address?.fullAddress(includingRegion: true, singleLine: true) ?? item.address?.fullAddress,
            city: address?.cityName,
            country: address?.regionName,
            countryCode: address?.region?.identifier,
            latitude: Self.round(item.location.coordinate.latitude, places: 6),
            longitude: Self.round(item.location.coordinate.longitude, places: 6),
            distanceMeters: distanceMeters.map { ($0 / 250).rounded() * 250 },
            timezone: item.timeZone?.identifier,
            phone: item.phoneNumber,
            url: item.url?.absoluteString
        )
    }

    private static func transportType(_ value: String) throws -> MKDirectionsTransportType {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "", "automobile", "driving": return .automobile
        case "walking": return .walking
        case "transit": return .transit
        case "cycling": return .cycling
        default: throw MapError.invalid("'transport' must be automobile, walking, transit, or cycling")
        }
    }

    private static func transportName(_ value: MKDirectionsTransportType) -> String {
        if value == .walking { return "walking" }
        if value == .transit { return "transit" }
        if value == .cycling { return "cycling" }
        return "automobile"
    }

    private static func launchDirectionsMode(_ value: String) throws -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "automobile", "driving": return MKLaunchOptionsDirectionsModeDriving
        case "walking": return MKLaunchOptionsDirectionsModeWalking
        case "transit": return MKLaunchOptionsDirectionsModeTransit
        case "cycling": return MKLaunchOptionsDirectionsModeCycling
        default: throw MapError.invalid("'directionsMode' must be automobile, walking, transit, or cycling")
        }
    }

    private static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func round(_ value: Double, places: Double) -> Double {
        let scale = pow(10, places)
        return (value * scale).rounded() / scale
    }
}
