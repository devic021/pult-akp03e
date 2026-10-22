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

    /// This app's own daemon, inside this bundle.
    ///
    /// Read from the running bundle rather than hard-coded to /Applications,
    /// so the agent follows the app wherever it was dragged to.
    static var daemonPath: URL {
        Bundle.main.bundleURL.appending(path: "Contents/MacOS/pultd")
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: agentPath.path)
    }

    /// Whether the installed agent points at *this* copy of the app.
    ///
    /// Worth asking separately from whether one exists at all: dragging the
    /// app somewhere else leaves an agent aimed at a path that is no longer
    /// there, and launchd fails quietly, so the dock simply never comes up and
    /// nothing says why.
    static var isCurrent: Bool {
        guard
            let data = try? Data(contentsOf: agentPath),
            let plist = try? PropertyListSerialization
                .propertyList(from: data, format: nil) as? [String: Any],
            let arguments = plist["ProgramArguments"] as? [String]
        else { return false }
        return arguments.first == daemonPath.path
    }

    /// Writes the login agent and starts it.
    ///
    /// The app has to be able to do this itself. Installed from a disk image
    /// there is no script to run — you drag the app across and open it — so if
    /// only `install.sh` could write this file, a dragged copy would come up
    /// connected to nothing and the disk image's own instructions would be a
    /// promise the app does not keep.
    @discardableResult
    static func install() -> Bool {
        let agent: [String: Any] = [
            "Label": label,
            "ProgramArguments": [daemonPath.path],
            "RunAtLoad": true,
            "KeepAlive": true,
            // launchd starts jobs with a bare PATH; `run` actions expect a
            // shell's one.
            "EnvironmentVariables": [
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            ],
            "StandardOutPath": logPath.path,
            "StandardErrorPath": logPath.path,
        ]

        do {
            try FileManager.default.createDirectory(
                at: agentPath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try PropertyListSerialization.data(
                fromPropertyList: agent, format: .xml, options: 0
            )
            try data.write(to: agentPath, options: .atomic)
        } catch {
            return false
        }

        // Any job already loaded is holding the old path, and launchd will not
        // replace one in place, so it goes before the new one comes up.
        _ = run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        setLoaded(true)
        return isLoaded()
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
