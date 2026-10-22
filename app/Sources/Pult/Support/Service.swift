import Foundation

/// The background service, as far as the app can manage it.
///
/// The app and the daemon are separate processes on purpose — only one of them
/// may hold the dock — so starting, stopping and restarting it goes through
/// `launchctl` rather than through any code shared between them.
enum Service {
    static let label = "dev.pult.daemon"

    static var agentPath: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appending(path: "Library/LaunchAgents/\(label).plist")
    }

    static var logPath: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appending(path: "Library/Logs/pult.log")
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: agentPath.path)
    }

    /// Whether launchd currently has the job, which is also what decides
    /// whether it comes back at the next login.
    static func isLoaded() -> Bool {
        run("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"]) == 0
    }

    static func restart() {
        _ = run("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/\(label)"])
    }

    static func setLoaded(_ loaded: Bool) {
        let domain = "gui/\(getuid())"
        if loaded {
            _ = run("/bin/launchctl", ["enable", "\(domain)/\(label)"])
            _ = run("/bin/launchctl", ["bootstrap", domain, agentPath.path])
        } else {
            _ = run("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
            _ = run("/bin/launchctl", ["disable", "\(domain)/\(label)"])
        }
    }

    @discardableResult
    private static func run(_ path: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}

/// What the app knows about itself.
enum About {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    static let author = "DT Development"
    static let device = "Ajazz AKP03E"

    /// What is bundled and under whose terms. Not decoration: the icon set and
    /// the device driver both ask for attribution.
    static let credits: [(String, String)] = [
        ("Lucide", "ISC — 1865 icons"),
        ("ajazz-sdk", "MPL-2.0 — device protocol"),
        ("resvg", "MPL-2.0 — SVG rendering"),
    ]
}
