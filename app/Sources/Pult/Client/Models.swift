import Foundation

/// Mirrors of what the daemon sends. The daemon owns the file format; the app
/// never parses TOML, it exchanges JSON and lets the daemon write the file.
///
/// Decoding is deliberately forgiving. The daemon leaves out anything empty so
/// the file it writes stays readable, and Swift's synthesised decoder does not
/// fall back to a property's default value for a missing key — it throws. Every
/// type below therefore decodes by hand, treating absence as the default.

struct Action: Codable, Equatable, Hashable {
    var app: String?
    var run: String?
    var shortcut: String?
    var scene: String?
    var volume: Int?
    var page: PageTurn?
    var hour: HourStep?

    var isEmpty: Bool {
        app == nil && run == nil && shortcut == nil
            && scene == nil && volume == nil && page == nil && hour == nil
    }

    /// Which of the mutually exclusive actions this is.
    var kind: Kind {
        if app != nil { return .app }
        if run != nil { return .run }
        if shortcut != nil { return .shortcut }
        if volume != nil { return .volume }
        if scene != nil { return .scene }
        if page != nil { return .page }
        if hour != nil { return .hour }
        return .none
    }

    enum Kind: String, CaseIterable, Identifiable {
        case none, app, run, shortcut, volume, scene, page, hour
        var id: String { rawValue }
        var label: String { T("action.\(rawValue)") }
    }

    /// One line saying what this does, for tooltips and lists.
    var summary: String {
        switch kind {
        case .none:
            return T("action.none")
        case .app:
            return "\(T("action.app")): \(app ?? "")"
        case .run:
            return "\(T("action.run")): \(run ?? "")"
        case .shortcut:
            return "\(T("action.shortcut")): \(shortcut ?? "")"
        case .volume:
            let value = volume ?? 0
            return "\(T("action.volume")): \(value > 0 ? "+" : "")\(value)"
        case .scene:
            return "\(T("action.scene")): \(scene ?? "")"
        case .page:
            return "\(T("action.page")): \(page?.label ?? "")"
        case .hour:
            return "\(T("action.hour")): \(hour?.label ?? "")"
        }
    }

    /// Switches to another kind of action, dropping the old one: a key can
    /// only carry one, and a leftover field would be written to the file.
    mutating func become(_ kind: Kind) {
        app = nil; run = nil; shortcut = nil; scene = nil
        volume = nil; page = nil; hour = nil
        switch kind {
        case .none: break
        case .app: app = ""
        case .run: run = ""
        case .shortcut: shortcut = ""
        case .volume: volume = 5
        case .scene: scene = ""
        case .page: page = .next
        case .hour: hour = .next
        }
    }
}

enum PageTurn: String, Codable, CaseIterable, Identifiable {
    case next, prev, first
    var id: String { rawValue }
    var label: String { T("action.page.\(rawValue)") }
}

/// Which hour of a forecast the whole scene reads from.
///
/// Scene-wide rather than per key: one key an hour ahead of the other five is
/// six numbers that do not belong to each other. The dock lets go of a scrub
/// on its own after twenty seconds.
enum HourStep: String, Codable, CaseIterable, Identifiable {
    case next, prev, now
    var id: String { rawValue }
    var label: String { T("action.hour.\(rawValue)") }
}

/// A colour chosen by a number, so a key's background is itself a reading.
struct Ramp: Codable, Equatable, Hashable {
    /// What to read, as `feed.field`.
    var field: String = ""
    /// Breakpoints, in order. Between two the colour is mixed; past either end
    /// it holds, because a temperature off the scale is still that end of it.
    var stops: [Stop] = []

    /// One breakpoint. The daemon writes it as a pair — `[-5, "#1f6feb"]` —
    /// so it decodes from an unkeyed container rather than from fields.
    struct Stop: Codable, Equatable, Hashable, Identifiable {
        var id = UUID()
        var value: Double = 0
        var color: String = "#4da3ff"

        init(value: Double, color: String) {
            self.value = value
            self.color = color
        }

        init(from decoder: Decoder) throws {
            var pair = try decoder.unkeyedContainer()
            value = try pair.decode(Double.self)
            color = try pair.decode(String.self)
        }

        func encode(to encoder: Encoder) throws {
            var pair = encoder.unkeyedContainer()
            try pair.encode(value)
            try pair.encode(color)
        }

        // `id` is for the list on screen, never for the file.
        static func == (a: Stop, b: Stop) -> Bool {
            a.value == b.value && a.color == b.color
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(value)
            hasher.combine(color)
        }
    }

    enum CodingKeys: String, CodingKey { case field, stops }

    init(field: String = "", stops: [Stop] = []) {
        self.field = field
        self.stops = stops
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        field = try values.decodeIfPresent(String.self, forKey: .field) ?? ""
        stops = try values.decodeIfPresent([Stop].self, forKey: .stops) ?? []
    }
}

/// One of the things a key can show. Pressing the key moves to the next.
///
/// The reading travels whole: `value`, `caption` and `ramp` come from the
/// member and are never inherited, because a caption describes the number
/// above it and a ramp colours that number. The icon is the key's identity, so
/// it carries over unless the member names its own.
struct KeyView: Codable, Equatable, Hashable, Identifiable {
    var id = UUID()
    var value: String?
    var caption: String?
    var ramp: Ramp?
    var icon: String?
    var icon_rotate: String?

    enum CodingKeys: String, CodingKey { case value, caption, ramp, icon, icon_rotate }

    init(value: String? = nil, caption: String? = nil) {
        self.value = value
        self.caption = caption
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        value = try values.decodeIfPresent(String.self, forKey: .value)
        caption = try values.decodeIfPresent(String.self, forKey: .caption)
        ramp = try values.decodeIfPresent(Ramp.self, forKey: .ramp)
        icon = try values.decodeIfPresent(String.self, forKey: .icon)
        icon_rotate = try values.decodeIfPresent(String.self, forKey: .icon_rotate)
    }

    static func == (a: KeyView, b: KeyView) -> Bool {
        a.value == b.value && a.caption == b.caption && a.ramp == b.ramp
            && a.icon == b.icon && a.icon_rotate == b.icon_rotate
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(value)
        hasher.combine(caption)
        hasher.combine(ramp)
        hasher.combine(icon)
        hasher.combine(icon_rotate)
    }
}

enum KeyAnimation: String, Codable, CaseIterable, Identifiable {
    case pulse, spin, blink
    var id: String { rawValue }
    var label: String { T("key.animate.\(rawValue)") }
}

struct Key: Codable, Equatable, Hashable, Identifiable {
    var id = UUID()

    var app: String?
    var label: String = ""
    var color: String?
    var text_color: String?
    var icon: String?
    var icon_color: String?
    /// Degrees to turn the icon. A template, so an arrow can point at a wind.
    var icon_rotate: String?
    var animate: KeyAnimation?

    /// The reading this key shows, as a template: `{vreme.temp|round}°`.
    /// A key with a value draws the value large and the label not at all.
    var value: String?
    /// The line under it, saying what the number is.
    var caption: String?
    /// A background chosen by the reading itself.
    var ramp: Ramp?
    /// The other things this key can show.
    var cycle: [KeyView] = []

    // Flattened in the daemon's JSON, so they sit beside the art here too.
    var run: String?
    var shortcut: String?
    var scene: String?
    var volume: Int?
    var page: PageTurn?
    var hour: HourStep?

    enum CodingKeys: String, CodingKey {
        case label, color, text_color, icon, icon_color, icon_rotate, animate
        case value, caption, ramp, cycle
        case app, run, shortcut, scene, volume, page, hour
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
        icon_rotate = try values.decodeIfPresent(String.self, forKey: .icon_rotate)
        animate = try values.decodeIfPresent(KeyAnimation.self, forKey: .animate)
        value = try values.decodeIfPresent(String.self, forKey: .value)
        caption = try values.decodeIfPresent(String.self, forKey: .caption)
        ramp = try values.decodeIfPresent(Ramp.self, forKey: .ramp)
        cycle = try values.decodeIfPresent([KeyView].self, forKey: .cycle) ?? []
        app = try values.decodeIfPresent(String.self, forKey: .app)
        run = try values.decodeIfPresent(String.self, forKey: .run)
        shortcut = try values.decodeIfPresent(String.self, forKey: .shortcut)
        scene = try values.decodeIfPresent(String.self, forKey: .scene)
        volume = try values.decodeIfPresent(Int.self, forKey: .volume)
        page = try values.decodeIfPresent(PageTurn.self, forKey: .page)
        hour = try values.decodeIfPresent(HourStep.self, forKey: .hour)
        extra = (try? decoder.container(keyedBy: AnyKey.self))?.unknown(except: Key.known) ?? [:]
    }

    /// Anything a newer daemon wrote that this version has no field for.
    var extra: [String: JSONValue] = [:]

    private static let known: Set<String> = [
        "label", "color", "text_color", "icon", "icon_color", "icon_rotate", "animate",
        "value", "caption", "ramp", "cycle",
        "app", "run", "shortcut", "scene", "volume", "page", "hour",
    ]

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        if !label.isEmpty { try values.encode(label, forKey: .label) }
        try values.encodeIfPresent(color, forKey: .color)
        try values.encodeIfPresent(text_color, forKey: .text_color)
        try values.encodeIfPresent(icon, forKey: .icon)
        try values.encodeIfPresent(icon_color, forKey: .icon_color)
        try values.encodeIfPresent(icon_rotate, forKey: .icon_rotate)
        try values.encodeIfPresent(animate, forKey: .animate)
        try values.encodeIfPresent(value, forKey: .value)
        try values.encodeIfPresent(caption, forKey: .caption)
        try values.encodeIfPresent(ramp, forKey: .ramp)
        if !cycle.isEmpty { try values.encode(cycle, forKey: .cycle) }
        try values.encodeIfPresent(app, forKey: .app)
        try values.encodeIfPresent(run, forKey: .run)
        try values.encodeIfPresent(shortcut, forKey: .shortcut)
        try values.encodeIfPresent(scene, forKey: .scene)
        try values.encodeIfPresent(volume, forKey: .volume)
        try values.encodeIfPresent(page, forKey: .page)
        try values.encodeIfPresent(hour, forKey: .hour)
        try encoder.encodeExtra(extra)
    }

    var action: Action {
        get {
            Action(
                app: app, run: run, shortcut: shortcut,
                scene: scene, volume: volume, page: page, hour: hour
            )
        }
        set {
            app = newValue.app
            run = newValue.run
            shortcut = newValue.shortcut
            scene = newValue.scene
            volume = newValue.volume
            page = newValue.page
            hour = newValue.hour
        }
    }

    var isBlank: Bool {
        label.isEmpty && icon == nil && action.isEmpty && !reads
    }

    /// Whether this key reports a number rather than doing something.
    ///
    /// A readout's press changes what it shows and fires no action: the daemon
    /// refuses a key that tries for both, because a press can only mean one
    /// thing.
    var reads: Bool { value != nil || !cycle.isEmpty }

    /// How many things this key can show.
    var views: Int { cycle.count + 1 }

    /// The key as its `index`th reading shows it, wrapping round. The same
    /// rule the daemon applies, so the editor's preview is the dock's.
    func view(_ index: Int) -> Key {
        let slot = views > 0 ? index % views - 1 : -1
        guard cycle.indices.contains(slot) else { return self }
        let overlay = cycle[slot]
        var shown = self
        shown.value = overlay.value
        shown.caption = overlay.caption
        shown.ramp = overlay.ramp
        shown.icon = overlay.icon ?? icon
        shown.icon_rotate = overlay.icon_rotate ?? icon_rotate
        return shown
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
            && a.icon_rotate == b.icon_rotate
            && a.animate == b.animate
            && a.value == b.value
            && a.caption == b.caption
            && a.ramp == b.ramp
            && a.cycle == b.cycle
            && a.action == b.action
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(label)
        hasher.combine(color)
        hasher.combine(text_color)
        hasher.combine(icon)
        hasher.combine(icon_color)
        hasher.combine(icon_rotate)
        hasher.combine(animate)
        hasher.combine(value)
        hasher.combine(caption)
        hasher.combine(ramp)
        hasher.combine(cycle)
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
    /// One drawing across the whole dock, instead of six separate pictures.
    /// Absent means six keys, which is what every scene was until canvases
    /// existed, so an older config keeps its meaning exactly.
    var surface: Surface?

    enum CodingKeys: String, CodingKey { case apps, keys, buttons, encoders, surface }

    init(
        apps: [String] = [],
        keys: [Key] = [],
        buttons: [Action] = [],
        encoders: [Knob] = [],
        surface: Surface? = nil
    ) {
        self.apps = apps
        self.keys = keys
        self.buttons = buttons
        self.encoders = encoders
        self.surface = surface
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        apps = try values.decodeIfPresent([String].self, forKey: .apps) ?? []
        keys = try values.decodeIfPresent([Key].self, forKey: .keys) ?? []
        buttons = try values.decodeIfPresent([Action].self, forKey: .buttons) ?? []
        encoders = try values.decodeIfPresent([Knob].self, forKey: .encoders) ?? []
        surface = try values.decodeIfPresent(Surface.self, forKey: .surface)
        extra = (try? decoder.container(keyedBy: AnyKey.self))?.unknown(except: DeckScene.known) ?? [:]
    }

    /// Anything a newer daemon added that this version has no case for.
    var extra: [String: JSONValue] = [:]

    private static let known: Set<String> = ["apps", "keys", "buttons", "encoders", "surface"]

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        if !apps.isEmpty { try values.encode(apps, forKey: .apps) }
        if !keys.isEmpty { try values.encode(keys, forKey: .keys) }
        if !buttons.isEmpty { try values.encode(buttons, forKey: .buttons) }
        if !encoders.isEmpty { try values.encode(encoders, forKey: .encoders) }
        try values.encodeIfPresent(surface, forKey: .surface)
        try encoder.encodeExtra(extra)
    }

    /// Whether this scene exists only to paint something.
    ///
    /// A canvas with no keys is not an application's scene — it is a look you
    /// switch the dock to. The buttons and knobs do not count: a drawing still
    /// needs a way back out, so every one of them carries "return to general"
    /// on a button, and counting that would put all of them back in the wrong
    /// list.
    var isJustADrawing: Bool {
        surface?.isCanvas == true && keys.isEmpty
    }

    /// Pages are implicit: six keys to a page.
    func pages(perPage: Int = 6) -> Int {
        max(1, Int(ceil(Double(keys.count) / Double(perPage))))
    }
}

/// When nobody has touched the Mac for a while, the dock stops being a
/// controller and becomes something to look at.
///
/// Absent means the dock never rests, which is what it did before any of this
/// existed — so a configuration written then keeps its meaning.
struct Idle: Codable, Equatable {
    /// How long since the last keystroke or pointer move: `30s`, `3m`, `1h`.
    var after: String = "3m"
    /// The scene to show. Any scene will do; a canvas is the point.
    var scene: String = ""
    /// Or a playlist, which wins over `scene`. Each member is a whole scene,
    /// so each keeps its own motion, colours, geometry and frame rate.
    var scenes: [String] = []
    var hold: String?
    var fade: Double?
    var fade_in: Double?
    /// `any` or `dock`.
    var wake_on: String?
    var brightness: Int?
    var dark_when_display_sleeps = false
    var swallow_first_press = true
    /// The frame the dock holds while the Mac sleeps. Nothing can animate
    /// then: the daemon is frozen along with everything else.
    var sleep_image: String?
    var extra: [String: JSONValue] = [:]

    enum CodingKeys: String, CodingKey {
        case after, scene, scenes, hold, fade, fade_in, wake_on, brightness
        case dark_when_display_sleeps, swallow_first_press, sleep_image
    }

    private static let known: Set<String> = [
        "after", "scene", "scenes", "hold", "fade", "fade_in", "wake_on",
        "brightness", "dark_when_display_sleeps", "swallow_first_press", "sleep_image",
    ]

    init(scene: String = "") {
        self.scene = scene
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        after = try values.decodeIfPresent(String.self, forKey: .after) ?? "3m"
        scene = try values.decodeIfPresent(String.self, forKey: .scene) ?? ""
        scenes = try values.decodeIfPresent([String].self, forKey: .scenes) ?? []
        hold = try values.decodeIfPresent(String.self, forKey: .hold)
        fade = try values.decodeIfPresent(Double.self, forKey: .fade)
        fade_in = try values.decodeIfPresent(Double.self, forKey: .fade_in)
        wake_on = try values.decodeIfPresent(String.self, forKey: .wake_on)
        brightness = try values.decodeIfPresent(Int.self, forKey: .brightness)
        dark_when_display_sleeps =
            try values.decodeIfPresent(Bool.self, forKey: .dark_when_display_sleeps) ?? false
        swallow_first_press =
            try values.decodeIfPresent(Bool.self, forKey: .swallow_first_press) ?? true
        sleep_image = try values.decodeIfPresent(String.self, forKey: .sleep_image)
        extra = (try? decoder.container(keyedBy: AnyKey.self))?.unknown(except: Idle.known) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(after, forKey: .after)
        try values.encode(scene, forKey: .scene)
        if !scenes.isEmpty { try values.encode(scenes, forKey: .scenes) }
        try values.encodeIfPresent(hold, forKey: .hold)
        try values.encodeIfPresent(fade, forKey: .fade)
        try values.encodeIfPresent(fade_in, forKey: .fade_in)
        try values.encodeIfPresent(wake_on, forKey: .wake_on)
        try values.encodeIfPresent(brightness, forKey: .brightness)
        try values.encode(dark_when_display_sleeps, forKey: .dark_when_display_sleeps)
        try values.encode(swallow_first_press, forKey: .swallow_first_press)
        try values.encodeIfPresent(sleep_image, forKey: .sleep_image)
        try encoder.encodeExtra(extra)
    }

    /// The playlist, or the single scene as a playlist of one, so a caller has
    /// one shape to handle instead of two.
    var playlist: [String] { scenes.isEmpty ? (scene.isEmpty ? [] : [scene]) : scenes }
}

struct Config: Codable, Equatable {
    var brightness: Int = 70
    var poll_ms: Int = 300
    var press_feedback: Bool = true
    var font: String?
    var defaultScene: String = "general"
    var scenes: [String: DeckScene] = [:]
    /// The screensaver. Absent means the dock never rests.
    var idle: Idle?

    enum CodingKeys: String, CodingKey {
        case brightness, poll_ms, press_feedback, font, scenes, idle
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
        idle = try values.decodeIfPresent(Idle.self, forKey: .idle)
        extra = (try? decoder.container(keyedBy: AnyKey.self))?.unknown(except: Config.known) ?? [:]
    }

    /// Whole tables this version knows nothing about — feeds, for one.
    var extra: [String: JSONValue] = [:]

    private static let known: Set<String> = [
        "brightness", "poll_ms", "press_feedback", "font", "default", "scenes", "idle",
    ]

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(brightness, forKey: .brightness)
        try values.encode(poll_ms, forKey: .poll_ms)
        try values.encode(press_feedback, forKey: .press_feedback)
        try values.encodeIfPresent(font, forKey: .font)
        try values.encode(defaultScene, forKey: .defaultScene)
        try values.encode(scenes, forKey: .scenes)
        try values.encodeIfPresent(idle, forKey: .idle)
        try encoder.encodeExtra(extra)
    }

    /// Scene names in a stable order, so the sidebar does not shuffle.
    var sceneNames: [String] { scenes.keys.sorted() }

    /// Scenes that drive the keys.
    ///
    /// A scene with a drawing *and* keys belongs here: it is an application's
    /// scene that happens to have a backdrop, and it is edited like one.
    var keyScenes: [String] {
        sceneNames.filter { scenes[$0].map { !$0.isJustADrawing } ?? true }
    }

    /// Scenes that are nothing but a drawing. They have their own pane, and
    /// listing them beside the applications was asking what a scene called
    /// "zora" had to do with Chrome and Mail.
    var drawingScenes: [String] {
        sceneNames.filter { scenes[$0]?.isJustADrawing ?? false }
    }
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
