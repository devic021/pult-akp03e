import AppKit
import Combine
import SwiftUI

/// Everything the interface shows, and the only place that talks to the daemon.
@MainActor
final class AppState: ObservableObject {
    private let client = ControlClient()

    @Published var config = Config()
    /// What is on disk, so unsaved changes can be seen and undone.
    @Published private(set) var saved = Config()
    @Published private(set) var status: Status?
    @Published private(set) var connected = false
    @Published var error: String?

    @Published var selectedScene: String?
    @Published var page = 0
    @Published var selectedKey: Int?

    @Published private(set) var icons: [String] = []
    /// Which key the dock reported as pressed, so the editor can echo it.
    @Published var livePress: Int?

    private var renders: [Key: NSImage] = [:]
    private var pending: Set<Key> = []

    var dirty: Bool { config != saved }

    var scene: DeckScene? {
        guard let name = selectedScene else { return nil }
        return config.scenes[name]
    }

    // MARK: - Loading

    func start() {
        refresh()
        listen()
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.connected else { return }
                self.refresh()
            }
        }
    }

    func refresh() {
        do {
            status = try client.send(["cmd": "status"], as: Status.self)
            let loaded = try client.send(["cmd": "config"], as: Config.self, field: "config")
            if !dirty || saved != loaded {
                // A file changed underneath us wins only when nothing is being
                // edited; otherwise the editor keeps what is in front of you.
                if !dirty { config = loaded }
                saved = loaded
            }
            if icons.isEmpty {
                icons = try client.send(["cmd": "icons"], as: [String].self, field: "icons")
            }
            if selectedScene == nil {
                selectedScene = status?.scene ?? config.sceneNames.first
            }
            connected = true
            error = nil
        } catch {
            connected = false
            self.error = error.localizedDescription
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
        guard let kind = event["event"] as? String else { return }
        switch kind {
        case "key_down":
            livePress = event["index"] as? Int
        case "key_up":
            livePress = nil
        case "app", "scene", "page":
            refreshStatusOnly()
        default:
            break
        }
    }

    private func refreshStatusOnly() {
        status = try? client.send(["cmd": "status"], as: Status.self)
    }

    // MARK: - Saving

    func save() {
        do {
            let data = try JSONEncoder().encode(config)
            let json = try JSONSerialization.jsonObject(with: data)
            try client.send(["cmd": "set_config", "config": json])
            saved = config
            error = nil
            renders.removeAll()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func revert() {
        config = saved
        renders.removeAll()
    }

    // MARK: - Device

    func setBrightness(_ value: Int) {
        try? client.send(["cmd": "brightness", "value": value])
    }

    func show(scene name: String) {
        try? client.send(["cmd": "scene", "name": name])
    }

    func show(page index: Int) {
        try? client.send(["cmd": "page", "value": index])
    }

    func sleepDock() { try? client.send(["cmd": "sleep"]) }
    func wakeDock() { try? client.send(["cmd": "wake"]) }

    func writeBootLogo(_ url: URL) -> Bool {
        do {
            try client.send(["cmd": "boot_logo", "path": url.path])
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    // MARK: - Rendering
    //
    // Key art is drawn by the daemon, not reimplemented here: the editor must
    // show the same pixels the dock will, including font, wrapping and icons.

    func image(for key: Key, size: Int = 120) -> NSImage? {
        if let hit = renders[key] { return hit }
        guard !pending.contains(key) else { return nil }
        pending.insert(key)

        Task.detached { [client, key] in
            var body: [String: Any] = ["cmd": "render_key", "size": size]
            if let data = try? JSONEncoder().encode(key),
               let json = try? JSONSerialization.jsonObject(with: data) {
                body["key"] = json
            }
            let reply = try? client.send(body)
            let image = (reply?["png"] as? String)
                .flatMap { Data(base64Encoded: $0) }
                .flatMap { NSImage(data: $0) }

            await MainActor.run { [weak self] in
                self?.pending.remove(key)
                if let image { self?.renders[key] = image }
            }
        }
        return nil
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

    func addScene(named name: String) {
        guard !name.isEmpty, config.scenes[name] == nil else { return }
        config.scenes[name] = DeckScene(keys: (0..<6).map { _ in Key() })
        selectedScene = name
        page = 0
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

    /// Bundle IDs of what is running, for the application picker.
    func runningApps() -> [(name: String, bundleID: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let id = app.bundleIdentifier else { return nil }
                return (app.localizedName ?? id, id)
            }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }
}
