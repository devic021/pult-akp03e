import Foundation

/// Mirrors of what the daemon sends. The daemon owns the file format; the app
/// never parses TOML, it exchanges JSON and lets the daemon write the file.
///
/// Decoding is deliberately forgiving. The daemon leaves out anything empty so
/// the file it writes stays readable, and Swift's synthesised decoder does not
/// fall back to a property's default value for a missing key — it throws. Every
/// type below therefore decodes by hand, treating absence as the default.

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
    /// only carry one, and a leftover field would be written to the file.
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

    init(
        label: String = "",
        color: String? = nil,
        text_color: String? = nil,
        icon: String? = nil,
        icon_color: String? = nil,
        animate: KeyAnimation? = nil
    ) {
        self.label = label
        self.color = color
        self.text_color = text_color
        self.icon = icon
        self.icon_color = icon_color
        self.animate = animate
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        label = try values.decodeIfPresent(String.self, forKey: .label) ?? ""
        color = try values.decodeIfPresent(String.self, forKey: .color)
        text_color = try values.decodeIfPresent(String.self, forKey: .text_color)
        icon = try values.decodeIfPresent(String.self, forKey: .icon)
        icon_color = try values.decodeIfPresent(String.self, forKey: .icon_color)
        animate = try values.decodeIfPresent(KeyAnimation.self, forKey: .animate)
        run = try values.decodeIfPresent(String.self, forKey: .run)
        shortcut = try values.decodeIfPresent(String.self, forKey: .shortcut)
        scene = try values.decodeIfPresent(String.self, forKey: .scene)
        volume = try values.decodeIfPresent(Int.self, forKey: .volume)
        page = try values.decodeIfPresent(PageTurn.self, forKey: .page)
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

    // `id` exists only to identify a row on screen and is not part of the
    // file, so a fresh decode invents a new one. Comparing it would make every
    // reload look like an edit, and would miss the render cache on every key.
    static func == (a: Key, b: Key) -> Bool {
        a.label == b.label
            && a.color == b.color
            && a.text_color == b.text_color
            && a.icon == b.icon
            && a.icon_color == b.icon_color
            && a.animate == b.animate
            && a.action == b.action
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(label)
        hasher.combine(color)
        hasher.combine(text_color)
        hasher.combine(icon)
        hasher.combine(icon_color)
        hasher.combine(animate)
        hasher.combine(action)
    }
}

struct Knob: Codable, Equatable, Hashable {
    var cw = Action()
    var ccw = Action()
    var press = Action()

    enum CodingKeys: String, CodingKey { case cw, ccw, press }

    init(cw: Action = Action(), ccw: Action = Action(), press: Action = Action()) {
        self.cw = cw
        self.ccw = ccw
        self.press = press
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        cw = try values.decodeIfPresent(Action.self, forKey: .cw) ?? Action()
        ccw = try values.decodeIfPresent(Action.self, forKey: .ccw) ?? Action()
        press = try values.decodeIfPresent(Action.self, forKey: .press) ?? Action()
    }
}

struct DeckScene: Codable, Equatable {
    var apps: [String] = []
    var keys: [Key] = []
    var buttons: [Action] = []
    var encoders: [Knob] = []

    enum CodingKeys: String, CodingKey { case apps, keys, buttons, encoders }

    init(apps: [String] = [], keys: [Key] = [], buttons: [Action] = [], encoders: [Knob] = []) {
        self.apps = apps
        self.keys = keys
        self.buttons = buttons
        self.encoders = encoders
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        apps = try values.decodeIfPresent([String].self, forKey: .apps) ?? []
        keys = try values.decodeIfPresent([Key].self, forKey: .keys) ?? []
        buttons = try values.decodeIfPresent([Action].self, forKey: .buttons) ?? []
        encoders = try values.decodeIfPresent([Knob].self, forKey: .encoders) ?? []
    }

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

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        brightness = try values.decodeIfPresent(Int.self, forKey: .brightness) ?? 70
        poll_ms = try values.decodeIfPresent(Int.self, forKey: .poll_ms) ?? 300
        press_feedback = try values.decodeIfPresent(Bool.self, forKey: .press_feedback) ?? true
        font = try values.decodeIfPresent(String.self, forKey: .font)
        defaultScene = try values.decodeIfPresent(String.self, forKey: .defaultScene) ?? "general"
        scenes = try values.decodeIfPresent([String: DeckScene].self, forKey: .scenes) ?? [:]
    }

    /// Scene names in a stable order, so the sidebar does not shuffle.
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
