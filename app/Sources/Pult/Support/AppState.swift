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

    /// Which pane is open. Held here rather than in the view, because changing
    /// the language or the text size rebuilds the view tree and would
    /// otherwise throw you back to the first pane.
    @Published var panel: Panel = .scenes

    @Published var selectedScene: String?
    /// Which drawing the Animations pane is editing.
    ///
    /// Its own selection, not the sidebar's. Sharing one would mean switching
    /// to Animations and back left you on a different scene than you were
    /// editing, and giving an application's scene a backdrop — the unusual
    /// case, reachable from the picker — would drag the sidebar with it.
    @Published var selectedDrawing: String?
    @Published var page = 0
    @Published var selection: Selection?

    @Published private(set) var icons: [String] = []
    /// Lucide's synonyms, so the picker can be searched by meaning.
    @Published private(set) var iconTags: [String: [String]] = [:]
    /// Which key the dock reported as pressed, so the editor can echo it.
    @Published var livePress: Int?

    /// What the daemon says it can paint, and what each motion can be told.
    /// Asked for once: it is a property of the daemon, not of a scene.
    @Published private(set) var catalogue = Catalogue.empty
    /// A short loop per effect, so one is chosen by looking rather than by
    /// reading a list of names.
    @Published private(set) var strips: [String: Film] = [:]
    /// Whether the dock is currently showing something nobody has saved.
    @Published private(set) var trialing = false
    private var catalogueWanted = false
    private var stripsWanted = false
    private var trialEnds: Date?

    /// Rendered key art, and the icon sheet for the picker.
    @Published private(set) var renders: [RenderRequest: NSImage] = [:]
    @Published private(set) var iconSheet: [String: NSImage] = [:]
    private var inFlight: Set<RenderRequest> = []
    private var iconsWanted: Set<String> = []
    private var iconBatchTimer: Timer?

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

    // MARK: - The surface catalogue

    /// Asks the daemon what it can paint.
    ///
    /// Once per launch. The catalogue is a property of the daemon's build, and
    /// re-asking on every view appearance would be a socket round trip inside
    /// a resize.
    func loadCatalogue() {
        guard !catalogueWanted else { return }
        catalogueWanted = true

        io.async { [client] in
            let reply = try? client.send(["cmd": "effects"])
            let catalogue: Catalogue? = reply
                .flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                .flatMap { try? JSONDecoder().decode(Catalogue.self, from: $0) }

            Task { @MainActor [weak self] in
                guard let self else { return }
                if let catalogue {
                    self.catalogue = catalogue
                } else {
                    // An older daemon has no catalogue, and the panel should
                    // say so rather than show an empty gallery that looks like
                    // a failure to load.
                    self.catalogueWanted = false
                }
            }
        }
    }

    /// One short loop per effect, for the gallery.
    ///
    /// Ten strips of ten frames is about 2 MB over the socket, which is why
    /// the client reads in chunks; it is asked for once and held.
    func loadStrips() {
        guard !stripsWanted, !catalogue.effects.isEmpty else { return }
        stripsWanted = true

        io.async { [client] in
            let reply = try? client.send(["cmd": "effect_strips", "frames": 10])
            let strips = (reply?["strips"] as? [String: Any]) ?? [:]

            var films: [String: Film] = [:]
            for (name, value) in strips {
                guard
                    let strip = value as? [String: Any],
                    let frames = strip["frames"] as? [Any]
                else { continue }

                let decoded: [[NSImage]] = frames.compactMap { frame in
                    guard let tiles = frame as? [Any] else { return nil }
                    let images = tiles.compactMap { tile in
                        (tile as? String)
                            .flatMap { Data(base64Encoded: $0) }
                            .flatMap { NSImage(data: $0) }
                    }
                    return images.isEmpty ? nil : images
                }
                guard !decoded.isEmpty else { continue }
                // A strip samples one whole loop however long that loop is,
                // and lava's is twenty-four seconds — played at its true
                // tempo its tile would sit almost still and read as a broken
                // thumbnail. A gallery tile is there to show the character of
                // a motion, not its speed, so every one of them loops in
                // about the same couple of seconds.
                let loop = (strip["seconds"] as? Double) ?? 2.0
                films[name] = Film(frames: decoded, seconds: Swift.min(Swift.max(loop, 1.5), 3.0))
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.strips = films
                if films.isEmpty { self.stripsWanted = false }
            }
        }
    }

    /// Puts a surface on the real dock for a moment, without saving it.
    ///
    /// The seams are the whole question, and no picture of a dock answers it.
    func tryOnDock(_ surface: Surface, seconds: Double = 20) {
        let body: [String: Any] = [
            "cmd": "try_canvas",
            "surface": surface.payload,
            "seconds": seconds,
        ]
        trialing = true
        trialEnds = Date().addingTimeInterval(seconds)

        io.async { [client] in
            let failure = (try? client.send(body)) == nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                if failure {
                    self.trialing = false
                    self.error = T("surface.try.failed")
                    return
                }
                // The daemon expires the trial on its own; this is only the
                // button's own state catching up, and it is deliberately a
                // little late rather than a little early — a Stop button that
                // disappears while the dock is still showing the trial is
                // worse than one that lingers.
                _ = try? await Task.sleep(for: .seconds(seconds + 0.5))
                if let ends = self.trialEnds, ends <= Date() {
                    self.trialing = false
                }
            }
        }
    }

    func stopTrial() {
        trialing = false
        trialEnds = nil
        io.async { [client] in
            _ = try? client.send(["cmd": "try_stop"])
        }
    }

    // MARK: - Loading

    func start() {
        refresh()
        listen()
    }

    func refresh() {
        io.async { [client] in
            let status = try? client.send(["cmd": "status"], as: Status.self)
            let config = try? client.send(["cmd": "config"], as: Config.self, field: "config")
            let iconReply = try? client.send(["cmd": "icons"])
            let icons = iconReply?["icons"] as? [String]
            let tags = iconReply?["tags"] as? [String: [String]]

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
                if let tags { self.iconTags = tags }
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

    /// Brightness, coalesced.
    ///
    /// A slider emits dozens of values a second. Sending each one opens a
    /// connection and waits for an answer, which piles up behind the drag and
    /// makes the dock lag the finger. Only the newest value is sent, at most
    /// every `brightnessInterval`, and the last one always goes out.
    private var brightnessPending: Int?
    private var brightnessSentAt = Date.distantPast
    private var brightnessTimer: Timer?
    private static let brightnessInterval: TimeInterval = 0.05

    func setBrightness(_ value: Int, final: Bool = false) {
        brightnessPending = value

        if final {
            flushBrightness()
            return
        }

        let elapsed = Date().timeIntervalSince(brightnessSentAt)
        if elapsed >= Self.brightnessInterval {
            flushBrightness()
        } else if brightnessTimer == nil {
            // Trailing edge: whatever the last value was still has to arrive.
            brightnessTimer = Timer.scheduledTimer(
                withTimeInterval: Self.brightnessInterval - elapsed,
                repeats: false
            ) { [weak self] _ in
                Task { @MainActor in self?.flushBrightness() }
            }
        }
    }

    private func flushBrightness() {
        brightnessTimer?.invalidate()
        brightnessTimer = nil
        guard let value = brightnessPending else { return }
        brightnessPending = nil
        brightnessSentAt = Date()
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
    func image(for key: Key, size: Int = 160, pages: RenderRequest.Pages? = nil) -> NSImage? {
        renders[RenderRequest(key: key, size: size, pages: pages)]
    }

    /// Draws whatever of `keys` is not cached yet, in one round trip.
    func prefetch(_ keys: [Key], size: Int = 160, pages: RenderRequest.Pages? = nil) {
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
    func prefetchCurrentPage(size: Int = 160) {
        guard let scene else { return }
        let perPage = 6
        let start = page * perPage
        let keys = Array(scene.keys.dropFirst(start).prefix(perPage))
        prefetch(keys, size: size)
    }

    /// Asks for an icon's art, batching whatever else is asked for in the same
    /// moment.
    ///
    /// There are nearly two thousand icons. Drawing them all on the chance the
    /// picker is opened would be seconds of work and megabytes over the socket,
    /// so the grid asks for what it is about to show and these are gathered
    /// into one request.
    func needIcon(_ name: String) {
        guard iconSheet[name] == nil, !iconsWanted.contains(name) else { return }
        iconsWanted.insert(name)

        guard iconBatchTimer == nil else { return }
        iconBatchTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.flushIconRequests() }
        }
    }

    private func flushIconRequests() {
        iconBatchTimer = nil
        let wanted = Array(iconsWanted.prefix(160))
        guard !wanted.isEmpty else { return }
        iconsWanted.subtract(wanted)

        io.async { [client] in
            let reply = try? client.send([
                "cmd": "icon_sheet",
                "size": 72,
                "names": wanted,
            ])
            let sheet = (reply?["icons"] as? [String: String]) ?? [:]
            let images = sheet.compactMapValues { encoded in
                Data(base64Encoded: encoded).flatMap { NSImage(data: $0) }
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.iconSheet.merge(images) { _, new in new }
                // Anything still waiting goes out in the next batch.
                if !self.iconsWanted.isEmpty { self.flushIconRequests() }
            }
        }
    }

    /// Names matching a search, by name and by Lucide's own synonyms.
    func searchIcons(_ query: String) -> [String] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return icons }

        return icons.filter { name in
            name.contains(needle) || (iconTags[name]?.contains { $0.contains(needle) } ?? false)
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

    /// A new scene that is nothing but a drawing.
    ///
    /// No keys, and one button bound back to the default scene. That button is
    /// not decoration: a canvas replaces the picture, so nothing on the dock
    /// says what the keys do any more, and without a way out the only way back
    /// is to switch applications.
    func addDrawing(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, config.scenes[trimmed] == nil else { return }

        var back = Action()
        back.scene = config.defaultScene
        var scene = DeckScene()
        scene.buttons = [back]
        scene.surface = Surface(kind: "canvas", effect: catalogue.effects.first?.name)
        config.scenes[trimmed] = scene
        selectedDrawing = trimmed
    }

    /// The drawing on screen in the Animations pane: the one chosen, or the
    /// first there is.
    var drawing: String? {
        if let chosen = selectedDrawing, config.scenes[chosen] != nil { return chosen }
        return config.drawingScenes.first
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
        if selectedDrawing == name { selectedDrawing = trimmed }
    }

    func deleteScene(_ name: String) {
        guard config.scenes.count > 1, name != config.defaultScene else { return }
        config.scenes.removeValue(forKey: name)
        if selectedScene == name { selectedScene = config.sceneNames.first }
        if selectedDrawing == name { selectedDrawing = nil }
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

    /// Icons of what is running, so the status bar can show a face rather than
    /// a bundle ID.
    @Published private(set) var runningIcons: [String: NSImage] = [:]

    private func refreshRunningApps() {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
        }

        running = apps
            .compactMap { app in
                guard let id = app.bundleIdentifier else { return nil }
                return RunningApp(name: app.localizedName ?? id, bundleID: id)
            }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }

        var icons: [String: NSImage] = [:]
        for app in apps {
            if let id = app.bundleIdentifier, let icon = app.icon {
                icons[id] = icon
            }
        }
        runningIcons = icons
    }

    /// The readable name of an application, falling back to its bundle ID.
    func name(ofApp bundleID: String) -> String {
        running.first { $0.bundleID == bundleID }?.name ?? bundleID
    }
}

extension Knob {
    /// Which of a knob's three bindings is being edited.
    enum Part: Hashable {
        case cw, ccw, press
    }
}
