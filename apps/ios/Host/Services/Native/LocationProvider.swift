import CoreLocation
import Foundation
import MapKit

@MainActor
final class LocationProvider {
    static let shared = LocationProvider()

    private static let cacheLifetime: TimeInterval = 30
    private static let coordinateStep = 0.05
    private static let coordinatePrecisionMeters = 5_000.0
    private static let fixTimeoutNanoseconds: UInt64 = 12_000_000_000

    struct Place: Encodable {
        let city: String?
        let region: String?
        let displayName: String?
        let country: String?
        let countryCode: String?
        let latitude: Double
        let longitude: Double
        let accuracy: String
        let authorizationAccuracy: String
        let horizontalAccuracyMeters: Double
        let capturedAt: String
        let timezone: String
    }

    private struct PendingFix {
        let id: UUID
        let task: Task<CLLocation, Error>
    }

    enum LocationError: LocalizedError {
        case denied
        case timedOut
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .denied:
                return "Location access is off for Ox. Ask the user to enable it in Settings › Privacy & Security › Location Services › Ox, then try again."
            case .timedOut:
                return "Couldn't determine the user's location before the request timed out. Ask them to try again somewhere with a clearer GPS or network signal."
            case .unavailable(let reason):
                return "Couldn't determine the user's location: \(reason)"
            }
        }
    }

    private var cachedFix: CLLocation?
    private var pendingFix: PendingFix?

    private init() {}

    func current() async throws -> Place {
        let location = try await currentFix()
        let mapItem = await Self.reverseGeocode(location)
        let address = mapItem?.addressRepresentations
        let coordinate = Self.approximate(location.coordinate)
        let authorizationAccuracy = CLLocationManager().accuracyAuthorization == .reducedAccuracy ? "reduced" : "full"
        let horizontalAccuracy = max(Self.coordinatePrecisionMeters, location.horizontalAccuracy.rounded())
        let city = address?.cityName
        Log.agent.info("location.fix accuracy=approximate authorization=\(authorizationAccuracy) meters=\(Int(horizontalAccuracy)) ageMs=\(Int(max(0, -location.timestamp.timeIntervalSinceNow) * 1_000)) city=\(city ?? "?")")
        return Place(
            city: city,
            region: Self.regionContext(address),
            displayName: address?.cityWithContext(.automatic),
            country: address?.regionName,
            countryCode: address?.region?.identifier,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            accuracy: "approximate",
            authorizationAccuracy: authorizationAccuracy,
            horizontalAccuracyMeters: horizontalAccuracy,
            capturedAt: ISO8601DateFormatter().string(from: location.timestamp),
            timezone: mapItem?.timeZone?.identifier ?? TimeZone.current.identifier
        )
    }

    func currentFix() async throws -> CLLocation {
        if let cachedFix, abs(cachedFix.timestamp.timeIntervalSinceNow) <= Self.cacheLifetime {
            Log.agent.info("location.fix cache-hit ageMs=\(Int(abs(cachedFix.timestamp.timeIntervalSinceNow) * 1_000))")
            return cachedFix
        }
        if let pendingFix {
            Log.agent.info("location.fix coalesced")
            return try await pendingFix.task.value
        }
        let id = UUID()
        let task = Task { @MainActor in try await self.acquireFix() }
        pendingFix = PendingFix(id: id, task: task)
        do {
            let location = try await task.value
            if pendingFix?.id == id {
                cachedFix = location
                pendingFix = nil
            }
            return location
        } catch {
            if pendingFix?.id == id { pendingFix = nil }
            throw error
        }
    }

    func requestAccess() async {
        let session = CLServiceSession(authorization: .whenInUse)
        defer { session.invalidate() }
        try? await ensureAuthorized(using: session)
    }

    private func ensureAuthorized(using session: CLServiceSession) async throws {
        do {
            for try await diagnostic in session.diagnostics {
                if diagnostic.authorizationDenied || diagnostic.authorizationDeniedGlobally || diagnostic.authorizationRestricted {
                    Log.agent.info("location.auth denied")
                    throw LocationError.denied
                }
                if diagnostic.authorizationRequestInProgress {
                    Log.agent.info("location.auth requesting")
                    continue
                }
                if diagnostic.insufficientlyInUse {
                    throw LocationError.unavailable("app is not active")
                }
                if diagnostic.serviceSessionRequired {
                    throw LocationError.unavailable("location service session is unavailable")
                }
                return
            }
        } catch let error as LocationError {
            throw error
        } catch {
            Log.agent.error("location.auth failed \(error.localizedDescription)")
            throw LocationError.unavailable(error.localizedDescription)
        }
        throw LocationError.unavailable("authorization ended without a result")
    }

    private func acquireFix() async throws -> CLLocation {
        let session = CLServiceSession(authorization: .whenInUse)
        defer { session.invalidate() }
        try await ensureAuthorized(using: session)
        return try await withThrowingTaskGroup(of: CLLocation.self) { group in
            group.addTask { @MainActor in try await self.requestFix() }
            group.addTask {
                try await Task.sleep(nanoseconds: Self.fixTimeoutNanoseconds)
                throw LocationError.timedOut
            }
            defer { group.cancelAll() }
            guard let location = try await group.next() else {
                throw LocationError.unavailable("no fix returned")
            }
            return location
        }
    }

    private func requestFix() async throws -> CLLocation {
        do {
            for try await update in CLLocationUpdate.liveUpdates() {
                if update.authorizationDenied || update.authorizationDeniedGlobally || update.authorizationRestricted {
                    Log.agent.info("location.auth denied")
                    throw LocationError.denied
                }
                if update.serviceSessionRequired {
                    throw LocationError.unavailable("location service session is unavailable")
                }
                if update.locationUnavailable {
                    Log.agent.info("location.fix waiting reason=unavailable")
                    continue
                }
                if let location = update.location,
                   location.horizontalAccuracy >= 0,
                   abs(location.timestamp.timeIntervalSinceNow) <= 60 {
                    return location
                }
            }
        } catch let error as LocationError {
            throw error
        } catch {
            Log.agent.error("location.fail \(error.localizedDescription)")
            throw LocationError.unavailable(error.localizedDescription)
        }
        throw LocationError.unavailable("no fix returned")
    }

    private static func reverseGeocode(_ location: CLLocation) async -> MKMapItem? {
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
        do {
            return try await request.mapItems.first
        } catch {
            Log.agent.warning("location.geocode failed \(error.localizedDescription)")
            return nil
        }
    }

    private static func approximate(_ coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let latitude = (coordinate.latitude / coordinateStep).rounded() * coordinateStep
        let longitude = (coordinate.longitude / coordinateStep).rounded() * coordinateStep
        return CLLocationCoordinate2D(
            latitude: cleanCoordinate(latitude),
            longitude: cleanCoordinate(longitude)
        )
    }

    private static func cleanCoordinate(_ value: Double) -> Double {
        Double(String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)) ?? value
    }

    private static func regionContext(_ address: MKAddressRepresentations?) -> String? {
        guard let context = address?.cityWithContext else { return nil }
        guard let city = address?.cityName, context.hasPrefix(city), context.count > city.count else { return context }
        let suffix = String(context.dropFirst(city.count)).trimmingCharacters(in: CharacterSet(charactersIn: ", "))
        return suffix.isEmpty ? nil : suffix
    }
}
