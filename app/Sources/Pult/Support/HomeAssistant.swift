import Foundation

/// The Home Assistant connection, as the app manages it.
///
/// The token is the canonical copy in the login keychain; the URL is a plain
/// preference. `apply()` mirrors both into `~/.config/pult/ha.env` (mode 600),
/// which the `ha.sh` helper sources, so the daemon's shell feed keeps working
/// without the token ever living in the configuration file or the script.
@MainActor
final class HomeAssistant: ObservableObject {
    static let shared = HomeAssistant()

    enum Status: Equatable {
        /// Not asked yet.
        case unknown
        /// A request is in flight.
        case checking
        /// Answered, and the token is accepted.
        case ready
        /// Answered, but the token is missing or refused.
        case unauthorized
        /// Nothing answered at the address.
        case unreachable
    }

    @Published var url: String {
        didSet { UserDefaults.standard.set(url, forKey: "ha.url") }
    }
    /// Held in the clear only while the pane is open; the saved copy is the
    /// keychain's. Editing it here does nothing until `apply()`.
    @Published var token: String
    @Published private(set) var status: Status = .unknown

    private static let tokenAccount = "homeassistant.token"

    /// Addresses tried by `detect()`, after whatever is already set: the box is
    /// usually not this Mac, so a remembered address comes first, then the two
    /// names a local install answers to.
    private static let candidates = [
        "http://homeassistant.local:8123",
        "http://localhost:8123",
    ]

    private init() {
        let env = Self.readEnv()
        url = UserDefaults.standard.string(forKey: "ha.url")
            ?? env["HA"]
            ?? ""
        token = Keychain.get(account: Self.tokenAccount)
            ?? env["TOKEN"]
            ?? ""
    }

    /// Whether anything is configured at all, so the pane can lead with setup
    /// rather than a status line about nothing.
    var configured: Bool { !url.isEmpty }

    // MARK: - Talking to the box

    /// Asks the configured address whether it is there and whether the token is
    /// accepted. `/api/` answers 200 with a valid token, 401 without one.
    func test() async {
        guard let request = apiRequest(for: url) else { status = .unreachable; return }
        status = .checking
        status = await probe(request)
    }

    /// Looks for a reachable box: the remembered address first, then the local
    /// names. The first that answers (even with 401, which still means it is
    /// there) is adopted. The token, if any, is kept.
    func detect() async {
        status = .checking
        let tried = ([url] + Self.candidates)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var seen = Set<String>()
        for address in tried where seen.insert(address).inserted {
            guard let request = apiRequest(for: address) else { continue }
            let result = await probe(request)
            if result == .ready || result == .unauthorized {
                url = address
                status = result
                return
            }
        }
        status = .unreachable
    }

    private func probe(_ request: URLRequest) async -> Status {
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
            case 200: return .ready
            case 401, 403: return .unauthorized
            default: return .unreachable
            }
        } catch {
            return .unreachable
        }
    }

    private func apiRequest(for base: String) -> URLRequest? {
        let trimmed = base.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty, let endpoint = URL(string: trimmed + "/api/") else { return nil }
        var request = URLRequest(url: endpoint, timeoutInterval: 6)
        let token = self.token.trimmingCharacters(in: .whitespaces)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    // MARK: - Saving

    /// Writes the token to the keychain and both values to the mode-600 file
    /// the helper reads. The configuration file is never touched.
    func apply() {
        let token = self.token.trimmingCharacters(in: .whitespaces)
        let url = self.url.trimmingCharacters(in: .whitespaces)
        self.token = token
        self.url = url
        Keychain.set(token.isEmpty ? nil : token, account: Self.tokenAccount)
        Self.writeEnv(url: url, token: token)
    }

    // MARK: - The handoff file

    private static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/pult", isDirectory: true)
    }

    private static var envFile: URL { directory.appendingPathComponent("ha.env") }

    private static func writeEnv(url: String, token: String) {
        let body = "HA=\"\(url)\"\nTOKEN=\"\(token)\"\n"
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard (try? body.write(to: envFile, atomically: true, encoding: .utf8)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: envFile.path)
    }

    /// Reads `HA` and `TOKEN` out of ha.env, so a first launch after the token
    /// moved out of the script still shows the connection already set up.
    private static func readEnv() -> [String: String] {
        guard let text = try? String(contentsOf: envFile, encoding: .utf8) else { return [:] }
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...]
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            values[key] = value
        }
        return values
    }
}
