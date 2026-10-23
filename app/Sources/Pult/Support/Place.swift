import CoreLocation
import Foundation

/// Asks macOS where this Mac is.
///
/// Entirely optional: the coordinates can be typed in instead, and the pane
/// offers both. Location is a permission people are right to be careful with,
/// so this asks only when the button is pressed, asks for kilometre accuracy
/// rather than the best available, and keeps nothing — the answer goes
/// straight to the daemon, which rounds it again before writing it down.
final class Locator: NSObject, ObservableObject, CLLocationManagerDelegate {
    /// Whether a request is in the air, so the button can say so.
    @Published private(set) var asking = false
    /// Why the last attempt did not produce coordinates.
    @Published var problem: String?

    private let manager = CLLocationManager()
    private var answer: ((Double, Double) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        // A kilometre is far more than the weather needs, and asking for less
        // precision is the one privacy decision available here that costs
        // nothing at all.
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    /// Asks once, calling back on the main thread if an answer arrives.
    func find(_ then: @escaping (Double, Double) -> Void) {
        answer = then
        problem = nil
        asking = true

        switch manager.authorizationStatus {
        case .notDetermined:
            // The answer arrives through the delegate; the request follows it.
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            finish(problem: T("feeds.place.denied"))
        default:
            manager.requestLocation()
        }
    }

    private func finish(problem: String?) {
        DispatchQueue.main.async { [weak self] in
            self?.asking = false
            self?.problem = problem
            if problem != nil { self?.answer = nil }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard asking else { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            break
        case .denied, .restricted:
            finish(problem: T("feeds.place.denied"))
        default:
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let where_ = locations.last else {
            finish(problem: T("feeds.place.failed"))
            return
        }
        let handler = answer
        answer = nil
        DispatchQueue.main.async { [weak self] in
            self?.asking = false
            self?.problem = nil
            handler?(where_.coordinate.latitude, where_.coordinate.longitude)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Said plainly, because the commonest cause is Location Services
        // being off altogether and the system error does not say so.
        finish(problem: error.localizedDescription)
    }
}
