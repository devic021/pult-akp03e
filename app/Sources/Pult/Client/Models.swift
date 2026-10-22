import Foundation

/// Mirrors of what the daemon sends. The daemon owns the file format; the app
/// never parses TOML, it exchanges JSON and lets the daemon write the file.

struct Action: Codable, Equatable, Hashable {
    var run: String?
    var shortcut: String?
    var scene: String?
    var volume: Int?
    var page: PageTurn?

    var isEmpty: Bool {
        run == nil && shortcut == nil && scene == nil && volume == nil && page == nil
    }

    /// Which of the mutually exclusive actions this is.
    var kind: Kind {
        if run != nil { return .run }
        if shortcut != nil { return .shortcut }
        if volume != nil { return .volume }
        if scene != nil { return .scene }
        if page != nil { return .page }
        return .none
    }

    enum Kind: String, CaseIterable, Identifiable {
        case none, run, shortcut, volume, scene, page
        var id: String { rawValue }
        var label: String { T("action.\(rawValue)") }
    }

    /// Switches to another kind of action, dropping the old one: a key can
    /// only carry one, and leaving a stale field would be saved to the file.
    mutating func become(_ kind: Kind) {
        run = nil; shortcut = nil; scene = nil; volume = nil; page = nil
        switch kind {
        case .none: break
        case .run: run = ""
        case .shortcut: shortcut = ""
        case .volume: volume = 5
        case .scene: scene = ""
        case .page: page = .next
        }
    }
}

enum PageTurn: String, Codable, CaseIterable, Identifiable {
    case next, prev, first
    var id: String { rawValue }
    var label: String { T("action.page.\(rawValue)") }
}

enum KeyAnimation: String, Codable, CaseIterable, Identifiable {
    case pulse, spin, blink
    var id: String { rawValue }
    var label: String { T("key.animate.\(rawValue)") }
}

struct Key: Codable, Equatable, Hashable, Identifiable {
    var id = UUID()

    var label: String = ""
    var color: String?
    var text_color: String?
    var icon: String?
    var icon_color: String?
    var animate: KeyAnimation?

    // Flattened in the daemon's JSON, so they sit beside the art here too.
    var run: String?
    var shortcut: String?
    var scene: String?
    var volume: Int?
    var page: PageTurn?

    enum CodingKeys: String, CodingKey {
        case label, color, text_color, icon, icon_color, animate
        case run, shortcut, scene, volume, page
    }

    var action: Action {
        get { Action(run: run, shortcut: shortcut, scene: scene, volume: volume, page: page) }
        set {
            run = newValue.run
            shortcut = newValue.shortcut
            scene = newValue.scene
            volume = newValue.volume
            page = newValue.page
        }
    }

    var isBlank: Bool {
        label.isEmpty && icon == nil && action.isEmpty
    }
}

struct Knob: Codable, Equatable, Hashable {
    var cw = Action()
    var ccw = Action()
    var press = Action()
}

struct DeckScene: Codable, Equatable {
    var apps: [String] = []
    var keys: [Key] = []
    var buttons: [Action] = []
    var encoders: [Knob] = []

    /// Pages are implicit: six keys to a page.
    func pages(perPage: Int = 6) -> Int {
        max(1, Int(ceil(Double(keys.count) / Double(perPage))))
    }
}

struct Config: Codable, Equatable {
    var brightness: Int = 70
    var poll_ms: Int = 300
    var press_feedback: Bool = true
    var font: String?
    var defaultScene: String = "general"
    var scenes: [String: DeckScene] = [:]

    enum CodingKeys: String, CodingKey {
        case brightness, poll_ms, press_feedback, font, scenes
        case defaultScene = "default"
    }

    /// DeckScene names in a stable order, so the sidebar does not shuffle.
    var sceneNames: [String] { scenes.keys.sorted() }
}

struct DeviceInfo: Codable, Equatable {
    var kind: String
    var serial: String
    var firmware: String
    var keys: Int
    var encoders: Int
    var buttons: Int
    var key_size: [Int]
    var boot_logo: [Int]?
}

struct Status: Codable {
    var device: DeviceInfo?
    var scene: String?
    var page: Int?
    var pages: Int?
    var app: String?
    var config_path: String?
    var keystrokes_allowed: Bool?
}
