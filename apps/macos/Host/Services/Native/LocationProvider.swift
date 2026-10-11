import CoreLocation
import Foundation
import MapKit

@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    static let shared = LocationProvider()

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

    private let manager = CLLocationManager()
    private var pending: [UUID: CheckedContinuation<CLLocation, Error>] = [:]
    private var cachedFix: CLLocation?

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func requestAccess() async {
        manager.requestWhenInUseAuthorization()
    }

    func current() async throws -> Place {
        let location = try await currentFix()
        let item = try? await MKReverseGeocodingRequest(location: location)?.mapItems.first
        let address = item?.addressRepresentations
        return Place(
            city: address?.cityName,
            region: address?.cityWithContext,
            displayName: address?.cityWithContext(.automatic),
            country: address?.regionName,
            countryCode: address?.region?.identifier,
            latitude: (location.coordinate.latitude / 0.05).rounded() * 0.05,
            longitude: (location.coordinate.longitude / 0.05).rounded() * 0.05,
            accuracy: "approximate",
            authorizationAccuracy: manager.accuracyAuthorization == .reducedAccuracy ? "reduced" : "full",
            horizontalAccuracyMeters: max(5_000, location.horizontalAccuracy.rounded()),
            capturedAt: ISODate.string(from: location.timestamp),
            timezone: item?.timeZone?.identifier ?? TimeZone.current.identifier
        )
    }

    func currentFix() async throws -> CLLocation {
        if let cachedFix, abs(cachedFix.timestamp.timeIntervalSinceNow) <= 30 { return cachedFix }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                manager.requestWhenInUseAuthorization()
                manager.startUpdatingLocation()
                Task {
                    try? await Task.sleep(for: .seconds(12))
                    finish(id: id, result: .failure(RuntimeError.bridge("Location request timed out.")))
                }
            }
        } onCancel: {
            Task { @MainActor in self.finish(id: id, result: .failure(CancellationError())) }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let fix = locations.last, fix.horizontalAccuracy >= 0,
              abs(fix.timestamp.timeIntervalSinceNow) <= 60 else { return }
        cachedFix = fix
        Log.service.info("MacLocation.fix accuracyMeters=\(Int(fix.horizontalAccuracy))")
        complete(.success(fix))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Log.service.error("MacLocation.failed error=\(error.localizedDescription)")
        complete(.failure(error))
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
            complete(.failure(RuntimeError.bridge("Location access is denied or restricted. Enable Ox Host in System Settings > Privacy & Security > Location Services.")))
        }
    }

    private func complete(_ result: Result<CLLocation, Error>) {
        for id in Array(pending.keys) { finish(id: id, result: result) }
    }

    private func finish(id: UUID, result: Result<CLLocation, Error>) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(with: result)
        if pending.isEmpty { manager.stopUpdatingLocation() }
    }
}
