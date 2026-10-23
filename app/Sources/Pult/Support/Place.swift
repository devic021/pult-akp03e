import CoreLocation
import Foundation

/// Asks macOS where this Mac is.
///
/// Entirely optional: the coordinates can be typed in instead, and the pane
/// offers both. Location is a permission people are right to be careful with,
/// so this asks only when the button is pressed, asks for kilometre accuracy
/// rather than the best available, and keeps nothing — the answer goes
/// straight to the daemon, which rounds it again before writing it down.
///
/// Every path out of `find` ends in `finish`. macOS will sometimes never
/// answer at all — Location Services off for the whole machine, or a bundle it
/// has quietly decided not to prompt for — and an interface stuck on "asking"
/// with no way out is worse than one that admits it does not know.
final class Locator: NSObject, ObservableObject, CLLocationManagerDelegate {
    /// Whether a request is in the air, so the button can say so.
    @Published private(set) var asking = false
    /// Why the last attempt did not produce coordinates.
    @Published var problem: String?

    /// How long to wait before saying nothing came back.
    private let patience: TimeInterval = 12

    private let manager = CLLocationManager()
    private var answer: ((Double, Double) -> Void)?
    /// Which attempt is current, so a late reply cannot finish a newer one.
    private var attempt = UUID()

    override init() {
        super.init()
        manager.delegate = self
        // A kilometre is far more than the weather needs, and asking for less
        // precision is the one privacy decision here that costs nothing.
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    /// Asks once, calling back on the main thread if an answer arrives.
    func find(_ then: @escaping (Double, Double) -> Void) {
        answer = then
        problem = nil
        asking = true

        let mine = UUID()
        attempt = mine

        // Off the main thread on purpose: this one blocks, and asking it on
        // the main thread stalls the window and earns a warning saying so.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let enabled = CLLocationManager.locationServicesEnabled()
            DispatchQueue.main.async {
                guard let self, self.attempt == mine else { return }
                guard enabled else {
                    self.finish(mine, problem: T("feeds.place.off"))
                    return
                }
                self.ask(mine)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + patience) { [weak self] in
            guard let self, self.attempt == mine, self.asking else { return }
            self.finish(mine, problem: T("feeds.place.silent"))
        }
    }

    private func ask(_ mine: UUID) {
        switch manager.authorizationStatus {
        case .notDetermined:
            // The prompt's answer arrives through the delegate; the request
            // for a position follows it there.
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            finish(mine, problem: T("feeds.place.denied"))
        default:
            manager.requestLocation()
        }
    }

    private func finish(_ mine: UUID, problem: String?, coordinates: (Double, Double)? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.attempt == mine else { return }
            let handler = self.answer
            self.answer = nil
            self.asking = false
            self.problem = problem
            if let coordinates {
                handler?(coordinates.0, coordinates.1)
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard asking else { return }
        let mine = attempt
        switch manager.authorizationStatus {
        case .notDetermined:
            // Still waiting on the person. The deadline covers the case where
            // the prompt never appeared at all.
            break
        case .denied, .restricted:
            finish(mine, problem: T("feeds.place.denied"))
        default:
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let mine = attempt
        guard let fix = locations.last else {
            finish(mine, problem: T("feeds.place.failed"))
            return
        }
        finish(mine, problem: nil, coordinates: (fix.coordinate.latitude, fix.coordinate.longitude))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Reported as macOS words it: the commonest cause is the service being
        // off altogether, and guessing at a friendlier sentence would hide it.
        finish(attempt, problem: error.localizedDescription)
    }
}
