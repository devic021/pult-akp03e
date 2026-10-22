import AppKit
import Combine
import SwiftUI

/// Everything the interface shows, and the only place that talks to the daemon.
///
/// Two rules keep the window responsive, and both were learned the hard way:
///
/// * Nothing blocks the main thread. Every socket call runs on `io` and comes
///   back through `MainActor`; a round trip is a millisecond until the moment
///   it is not, and a frozen window is a far worse failure than a stale one.
/// * A view body only ever *reads*. Rendering is asked for by `prefetch`, from
///   a task tied to what is on screen, never from inside `body` — a body that
///   starts work runs again, and again, on every resize.
@MainActor
final class AppState: ObservableObject {
    private let client = ControlClient()
    private let io = DispatchQueue(label: "dev.pult.io", qos: .userInitiated)

    @Published var config = Config()
    /// What is on disk, so unsaved changes can be seen and undone.
    @Published private(set) var saved = Config()
    @Published private(set) var status: Status?
    @Published private(set) var connected = false
    @Published var error: String?

    @Published var selectedScene: String?
    @Published var page = 0
    @Published var selection: Selection?

    @Published private(set) var icons: [String] = []
    /// Which key the dock reported as pressed, so the editor can echo it.
    @Published var livePress: Int?

    /// Rendered key art, and the icon sheet for the picker.
    @Published private(set) var renders: [RenderRequest: NSImage] = [:]
    @Published private(set) var iconSheet: [String: NSImage] = [:]
    private var inFlight: Set<RenderRequest> = []
    private var iconSheetLoading = false

    /// What the inspector is editing.
    enum Selection: Hashable {
        case key(Int)
        case knob(Int, Knob.Part)
        case button(Int)
    }

    var dirty: Bool { config != saved }

    var scene: DeckScene? {
        guard let name = selectedScene else { return nil }
        return config.scenes[name]
    }

    var pages: Int { scene?.pages() ?? 1 }

    // MARK: - Loading

    func start() {
        refresh()
        listen()
    }

    func refresh() {
        io.async { [client] in
            let status = try? client.send(["cmd": "status"], as: Status.self)
            let config = try? client.send(["cmd": "config"], as: Config.self, field: "config")
            let icons = try? client.send(["cmd": "icons"], as: [String].self, field: "icons")

            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let status, let config else {
                    self.connected = false
                    return
                }

                self.status = status
                self.saved = config
                // A file changed underneath us wins only when nothing is being
                // edited; otherwise the editor keeps what is in front of you.
                if !self.dirty || self.config.scenes.isEmpty {
                    self.config = config
                }
                if let icons { self.icons = icons }
                if self.selectedScene == nil {
                    self.selectedScene = status.scene ?? config.sceneNames.first
                }
                self.connected = true
                self.error = nil
            }
        }
    }

    private func listen() {
        client.subscribe { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        } onClose: { [weak self] in
            Task { @MainActor in
                self?.connected = false
                // The daemon restarts on its own; pick it back up when it does.
                try? await Task.sleep(for: .seconds(2))
                self?.refresh()
                self?.listen()
            }
        }
    }

    private func handle(_ event: [String: Any]) {
        switch event["event"] as? String {
        case "key_down":
            livePress = event["index"] as? Int
        case "key_up":
            livePress = nil
        case "app", "scene", "page", "device":
            // Cheap: one field of one reply, and still off the main thread.
            io.async { [client] in
                let status = try? client.send(["cmd": "status"], as: Status.self)
                Task { @MainActor [weak self] in
                    if let status { self?.status = status }
                }
            }
        default:
            break
        }
    }

    // MARK: - Saving

    func save() {
        guard let json = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(config))
        else { return }

        let sending = config
        io.async { [client] in
            do {
                try client.send(["cmd": "set_config", "config": json])
                Task { @MainActor [weak self] in
                    self?.saved = sending
                    self?.error = nil
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.error = error.localizedDescription
                }
            }
        }
    }

    func revert() {
        config = saved
    }

    // MARK: - Device

    func setBrightness(_ value: Int) {
        fireAndForget(["cmd": "brightness", "value": value])
    }

    func show(scene name: String) {
        fireAndForget(["cmd": "scene", "name": name])
    }

    func show(page index: Int) {
        fireAndForget(["cmd": "page", "value": index])
    }

    func sleepDock() { fireAndForget(["cmd": "sleep"]) }
    func wakeDock() { fireAndForget(["cmd": "wake"]) }

    func writeBootLogo(_ url: URL, then report: @escaping (String?) -> Void) {
        io.async { [client] in
            var message: String?
            do {
                try client.send(["cmd": "boot_logo", "path": url.path])
            } catch {
                message = error.localizedDescription
            }
            Task { @MainActor in report(message) }
        }
    }

    private func fireAndForget(_ request: [String: Any]) {
        io.async { [client] in try? client.send(request) }
    }

    // MARK: - Rendering
    //
    // Key art is drawn by the daemon, not reimplemented here: the editor must
    // show the same pixels the dock will, including font, wrapping and icons.

    struct RenderRequest: Hashable {
        let key: Key
        let size: Int
        let pages: Pages?

        struct Pages: Hashable {
            let page: Int
            let total: Int
        }
    }

    /// Reads the cache. Never starts work: see the note at the top.
    func image(for key: Key, size: Int = 120, pages: RenderRequest.Pages? = nil) -> NSImage? {
        renders[RenderRequest(key: key, size: size, pages: pages)]
    }

    /// Draws whatever of `keys` is not cached yet, in one round trip.
    func prefetch(_ keys: [Key], size: Int = 120, pages: RenderRequest.Pages? = nil) {
        let wanted = keys.map { RenderRequest(key: $0, size: size, pages: pages) }
        let missing = wanted.filter { renders[$0] == nil && !inFlight.contains($0) }
        guard !missing.isEmpty else { return }

        missing.forEach { inFlight.insert($0) }

        let payload = missing.compactMap { request -> Any? in
            guard let data = try? JSONEncoder().encode(request.key) else { return nil }
            return try? JSONSerialization.jsonObject(with: data)
        }
        var body: [String: Any] = ["cmd": "render_keys", "keys": payload, "size": size]
        if let pages { body["pages"] = [pages.page, pages.total] }

        io.async { [client] in
            let reply = try? client.send(body)
            let pngs = (reply?["pngs"] as? [Any]) ?? []
            let images: [NSImage?] = pngs.map { entry in
                (entry as? String)
                    .flatMap { Data(base64Encoded: $0) }
                    .flatMap { NSImage(data: $0) }
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                for (request, image) in zip(missing, images) {
                    self.inFlight.remove(request)
                    if let image { self.renders[request] = image }
                }
                // Whatever the daemon could not draw is not asked for again
                // until something about the key changes.
                missing.forEach { self.inFlight.remove($0) }
            }
        }
    }

    /// Draws the keys of the page on screen.
    func prefetchCurrentPage(size: Int = 120) {
        guard let scene else { return }
        let perPage = 6
        let start = page * perPage
        let keys = Array(scene.keys.dropFirst(start).prefix(perPage))
        prefetch(keys, size: size)
    }

    /// Every bundled icon at picker size, in one round trip rather than 93.
    func loadIconSheet() {
        guard iconSheet.isEmpty, !iconSheetLoading else { return }
        iconSheetLoading = true

        io.async { [client] in
            let reply = try? client.send(["cmd": "icon_sheet", "size": 72])
            let sheet = (reply?["icons"] as? [String: String]) ?? [:]
            let images = sheet.compactMapValues { encoded in
                Data(base64Encoded: encoded).flatMap { NSImage(data: $0) }
            }

            Task { @MainActor [weak self] in
                self?.iconSheet = images
                self?.iconSheetLoading = false
            }
        }
    }

    // MARK: - Editing

    func updateScene(_ name: String, _ change: (inout DeckScene) -> Void) {
        guard var scene = config.scenes[name] else { return }
        change(&scene)
        config.scenes[name] = scene
    }

    /// The key at a grid position, or nil where the page runs out.
    func key(at slot: Int) -> Key? {
        guard let scene else { return nil }
        let index = page * 6 + slot
        return index < scene.keys.count ? scene.keys[index] : nil
    }

    func setKey(_ key: Key?, at slot: Int) {
        guard let name = selectedScene else { return }
        updateScene(name) { scene in
            let index = self.page * 6 + slot
            // Fill the gap so a key can be placed on an empty slot of a short page.
            while scene.keys.count < index {
                scene.keys.append(Key())
            }
            if let key {
                if index < scene.keys.count {
                    scene.keys[index] = key
                } else {
                    scene.keys.append(key)
                }
            } else if index < scene.keys.count {
                scene.keys[index] = Key()
            }
        }
    }

    /// Moves a key within the scene, across pages if need be.
    func moveKey(from: Int, to: Int) {
        guard let name = selectedScene, let scene else { return }
        let source = page * 6 + from
        let destination = page * 6 + to
        guard source < scene.keys.count else { return }

        updateScene(name) { scene in
            while scene.keys.count <= max(source, destination) {
                scene.keys.append(Key())
            }
            scene.keys.swapAt(source, destination)
        }
    }

    func addScene(named name: String) {
        guard !name.isEmpty, config.scenes[name] == nil else { return }
        config.scenes[name] = DeckScene(keys: (0..<6).map { _ in Key() })
        selectedScene = name
        page = 0
    }

    func renameScene(_ name: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != name, config.scenes[trimmed] == nil,
              let scene = config.scenes[name]
        else { return }

        config.scenes.removeValue(forKey: name)
        config.scenes[trimmed] = scene
        if config.defaultScene == name { config.defaultScene = trimmed }
        // A scene that pointed at the old name would otherwise dangle.
        for (key, var other) in config.scenes {
            var touched = false
            for index in other.keys.indices where other.keys[index].scene == name {
                other.keys[index].scene = trimmed
                touched = true
            }
            if touched { config.scenes[key] = other }
        }
        if selectedScene == name { selectedScene = trimmed }
    }

    func deleteScene(_ name: String) {
        guard config.scenes.count > 1, name != config.defaultScene else { return }
        config.scenes.removeValue(forKey: name)
        if selectedScene == name { selectedScene = config.sceneNames.first }
    }

    func addPage() {
        guard let name = selectedScene, let scene else { return }
        let target = scene.pages() * 6
        updateScene(name) { scene in
            while scene.keys.count < target + 6 {
                scene.keys.append(Key())
            }
        }
        page = scene.pages()
    }

    // MARK: - Applications
    //
    // Enumerating running applications is not free, and the picker that needs
    // it is rebuilt on every resize, so it is held and refreshed on launch and
    // quit instead of being asked for from a view body.

    @Published private(set) var running: [RunningApp] = []

    struct RunningApp: Identifiable, Hashable {
        let name: String
        let bundleID: String
        var id: String { bundleID }
    }

    func watchRunningApps() {
        refreshRunningApps()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshRunningApps() }
            }
        }
    }

    private func refreshRunningApps() {
        running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let id = app.bundleIdentifier else { return nil }
                return RunningApp(name: app.localizedName ?? id, bundleID: id)
            }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }
}

extension Knob {
    /// Which of a knob's three bindings is being edited.
    enum Part: Hashable {
        case cw, ccw, press
    }
}
