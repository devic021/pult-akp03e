import AppKit

/// The applications on this Mac, with their icons.
///
/// Reading the disk and every Info.plist is not something a view body can do,
/// so the list is built once on demand and held.
@MainActor
final class Installed: ObservableObject {
    static let shared = Installed()

    struct App: Identifiable, Hashable {
        let name: String
        let bundleID: String
        let url: URL
        var id: String { bundleID }
    }

    @Published private(set) var apps: [App] = []
    private var loading = false

    /// Where key icons taken from application bundles are kept, so the daemon
    /// can read them back as ordinary image files.
    static var iconDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appending(path: ".config/pult/icons", directoryHint: .isDirectory)
    }

    func load() {
        guard apps.isEmpty, !loading else { return }
        loading = true

        Task.detached(priority: .userInitiated) {
            let found = Installed.scan()
            await MainActor.run {
                self.apps = found
                self.loading = false
            }
        }
    }

    private nonisolated static func scan() -> [App] {
        let roots = [
            "/Applications",
            "/System/Applications",
            NSHomeDirectory() + "/Applications",
        ].map { URL(fileURLWithPath: $0) }

        var found: [String: App] = [:]
        let manager = FileManager.default

        for root in roots {
            guard let entries = try? manager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil
            ) else { continue }

            for entry in entries {
                if entry.pathExtension == "app" {
                    if let app = read(entry) { found[app.bundleID] = app }
                    continue
                }
                // One level down covers /Applications/Utilities and the like.
                guard let inner = try? manager.contentsOfDirectory(
                    at: entry,
                    includingPropertiesForKeys: nil
                ) else { continue }
                for candidate in inner where candidate.pathExtension == "app" {
                    if let app = read(candidate) { found[app.bundleID] = app }
                }
            }
        }

        return found.values.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    private nonisolated static func read(_ url: URL) -> App? {
        guard let bundle = Bundle(url: url),
              let id = bundle.bundleIdentifier
        else { return nil }

        let name = (bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle.infoDictionary?["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent

        return App(name: name, bundleID: id, url: url)
    }

    func icon(for app: App) -> NSImage {
        NSWorkspace.shared.icon(forFile: app.url.path)
    }

    /// Writes an application's icon out as a PNG the daemon can draw on a key,
    /// and returns the path to put in the key's `icon`.
    func exportIcon(for app: App) -> String? {
        let directory = Self.iconDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let destination = directory.appending(path: "\(app.bundleID).png")
        let image = icon(for: app)

        // 256 is plenty: the key is 60 px, and the daemon scales it down.
        let side = 256
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }

        representation.size = NSSize(width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
        image.draw(
            in: NSRect(x: 0, y: 0, width: side, height: side),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()

        guard let data = representation.representation(using: .png, properties: [:]) else {
            return nil
        }
        do {
            try data.write(to: destination)
        } catch {
            return nil
        }
        return destination.path
    }
}
