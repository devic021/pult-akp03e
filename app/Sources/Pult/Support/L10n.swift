import SwiftUI

/// Which language the interface speaks.
enum Language: String, CaseIterable, Identifiable {
    case system, sr, en

    var id: String { rawValue }

    /// Shown in the picker, each in its own language rather than translated.
    var label: String {
        switch self {
        case .system: return L10n.shared.resolved == .sr ? "Sistemski" : "System"
        case .sr: return "Srpski"
        case .en: return "English"
        }
    }
}

/// The interface text, in both languages.
///
/// Adding a string means adding one line to each table below; nothing else in
/// the app needs to change. Missing keys fall back to English and then to the
/// key itself, so a half-translated build still runs.
///
/// The resolved language and its table are held, not recomputed: `T()` is
/// called dozens of times per view body, and asking Foundation for the user's
/// preferred languages that often is enough to make a window resize stutter.
final class L10n: ObservableObject {
    static let shared = L10n()

    @Published private(set) var resolved: Language = .en
    private var table: [String: String] = L10n.en

    var language: Language {
        get { Language(rawValue: UserDefaults.standard.string(forKey: "language") ?? "") ?? .system }
        set {
            guard newValue != language else { return }
            UserDefaults.standard.set(newValue.rawValue, forKey: "language")
            adopt(newValue)
        }
    }

    private init() {
        adopt(language)
    }

    private func adopt(_ language: Language) {
        let resolved: Language
        if language == .system {
            let preferred = Locale.preferredLanguages.first ?? "en"
            resolved = ["sr", "hr", "bs"].contains(where: preferred.hasPrefix) ? .sr : .en
        } else {
            resolved = language
        }

        table = resolved == .sr ? Self.sr : Self.en
        self.resolved = resolved
    }

    func callAsFunction(_ key: String) -> String {
        table[key] ?? Self.en[key] ?? key
    }

    static let en: [String: String] = [
        "app.name": "Pult",
        "nav.scenes": "Scenes",
        "nav.device": "Device",
        "nav.settings": "Settings",
        "nav.about": "About",

        "scene.new": "New scene",
        "scene.delete": "Delete scene",
        "scene.rename": "Name",
        "scene.apps": "Applications",
        "scene.apps.help": "Bundle IDs this scene claims. A trailing * matches a prefix.",
        "scene.apps.add": "Add from running apps",
        "scene.default": "Default scene",
        "scene.isDefault": "Shown when no scene claims the app in front",
        "scene.keys": "Keys",
        "scene.show": "Show on the dock",
        "key.title": "Key",
        "inspector.hint": "Pick a key, a knob or a button on the dock to edit it",
        "scene.page": "Page",
        "scene.page.add": "Add page",
        "scene.encoders": "Knobs",
        "scene.buttons": "Round buttons",

        "key.empty": "Empty",
        "key.label": "Label",
        "key.icon": "Icon",
        "key.icon.none": "None",
        "key.icon.choose": "Choose icon",
        "key.color": "Background",
        "key.textColor": "Label colour",
        "key.iconColor": "Icon colour",
        "key.animate": "Animation",
        "key.animate.none": "None",
        "key.animate.pulse": "Pulse",
        "key.animate.spin": "Spin",
        "key.animate.blink": "Blink",
        "key.clear": "Clear key",
        "key.auto": "Automatic",

        "action.title": "Action",
        "action.none": "Nothing",
        "action.app": "Open application",
        "action.app.choose": "Choose application…",
        "action.run": "Run command",
        "action.shortcut": "Keystroke",
        "action.volume": "Volume",
        "action.scene": "Switch scene",
        "action.page": "Turn page",
        "action.page.next": "Next",
        "action.page.prev": "Previous",
        "action.page.first": "First",
        "action.shortcut.help": "For example cmd+shift+4, ctrl+left, f8",
        "action.run.help": "Runs through /bin/sh, detached",

        "encoder.0": "Small left knob",
        "encoder.1": "Big knob",
        "encoder.2": "Small right knob",
        "encoder.cw": "Turn right",
        "encoder.ccw": "Turn left",
        "encoder.press": "Press",
        "button.n": "Button %@",

        "device.title": "Device",
        "device.model": "Model",
        "device.serial": "Serial",
        "device.firmware": "Firmware",
        "device.keys": "Keys",
        "device.brightness": "Brightness",
        "device.bootLogo": "Boot logo",
        "device.bootLogo.help": "The only thing stored on the dock itself. Shown while it starts up.",
        "device.bootLogo.choose": "Choose image…",
        "device.bootLogo.written": "Written to the dock",
        "device.sleep": "Sleep",
        "device.wake": "Wake",
        "device.disconnected": "Dock not connected",

        "settings.language": "Language",
        "settings.theme": "Appearance",
        "theme.system": "System",
        "theme.light": "Light",
        "theme.dark": "Dark",
        "settings.pressFeedback": "Light keys up when pressed",
        "settings.poll": "App check interval",
        "settings.poll.help": "How often to ask macOS which app is in front",
        "settings.startup": "Start at login",
        "settings.permission": "Keystroke permission",
        "settings.permission.ok": "Granted",
        "settings.permission.missing": "Not granted — keystroke keys will do nothing",
        "settings.permission.open": "Open settings",
        "settings.config": "Configuration file",
        "settings.config.reveal": "Show in Finder",

        "status.connected": "Connected",
        "status.disconnected": "Daemon not running",
        "status.front": "In front",
        "status.scene": "Scene",
        "status.unsaved": "Unsaved changes",
        "status.save": "Save",
        "status.revert": "Revert",
        "status.saved": "Saved",

        "menu.open": "Open Pult",
        "menu.quit": "Quit",
        "error.title": "Something went wrong",
    ]

    static let sr: [String: String] = [
        "app.name": "Pult",
        "nav.scenes": "Scene",
        "nav.device": "Uređaj",
        "nav.settings": "Podešavanja",
        "nav.about": "O programu",

        "scene.new": "Nova scena",
        "scene.delete": "Obriši scenu",
        "scene.rename": "Naziv",
        "scene.apps": "Aplikacije",
        "scene.apps.help": "Bundle ID-evi koje ova scena preuzima. Zvezdica na kraju hvata prefiks.",
        "scene.apps.add": "Dodaj iz pokrenutih",
        "scene.default": "Podrazumevana scena",
        "scene.isDefault": "Prikazuje se kad nijedna scena ne preuzme aplikaciju u fokusu",
        "scene.keys": "Tasteri",
        "scene.show": "Prikaži na doku",
        "key.title": "Taster",
        "inspector.hint": "Izaberi taster, točak ili dugme na doku da ga podesiš",
        "scene.page": "Strana",
        "scene.page.add": "Dodaj stranu",
        "scene.encoders": "Točkovi",
        "scene.buttons": "Okrugla dugmad",

        "key.empty": "Prazno",
        "key.label": "Natpis",
        "key.icon": "Ikona",
        "key.icon.none": "Bez ikone",
        "key.icon.choose": "Izaberi ikonu",
        "key.color": "Pozadina",
        "key.textColor": "Boja natpisa",
        "key.iconColor": "Boja ikone",
        "key.animate": "Animacija",
        "key.animate.none": "Bez",
        "key.animate.pulse": "Disanje",
        "key.animate.spin": "Vrtnja",
        "key.animate.blink": "Treptanje",
        "key.clear": "Isprazni taster",
        "key.auto": "Automatski",

        "action.title": "Akcija",
        "action.none": "Ništa",
        "action.app": "Pokreni aplikaciju",
        "action.app.choose": "Izaberi aplikaciju…",
        "action.run": "Pokreni komandu",
        "action.shortcut": "Prečica",
        "action.volume": "Jačina zvuka",
        "action.scene": "Promeni scenu",
        "action.page": "Okreni stranu",
        "action.page.next": "Sledeća",
        "action.page.prev": "Prethodna",
        "action.page.first": "Prva",
        "action.shortcut.help": "Na primer cmd+shift+4, ctrl+left, f8",
        "action.run.help": "Izvršava se kroz /bin/sh, odvojeno od programa",

        "encoder.0": "Levi mali točak",
        "encoder.1": "Veliki točak",
        "encoder.2": "Desni mali točak",
        "encoder.cw": "Okret udesno",
        "encoder.ccw": "Okret ulevo",
        "encoder.press": "Pritisak",
        "button.n": "Dugme %@",

        "device.title": "Uređaj",
        "device.model": "Model",
        "device.serial": "Serijski broj",
        "device.firmware": "Firmver",
        "device.keys": "Tastera",
        "device.brightness": "Osvetljenost",
        "device.bootLogo": "Logo pri pokretanju",
        "device.bootLogo.help": "Jedino što sam uređaj trajno pamti. Prikazuje se dok se pokreće.",
        "device.bootLogo.choose": "Izaberi sliku…",
        "device.bootLogo.written": "Upisano u uređaj",
        "device.sleep": "Uspavaj",
        "device.wake": "Probudi",
        "device.disconnected": "Uređaj nije povezan",

        "settings.language": "Jezik",
        "settings.theme": "Izgled",
        "theme.system": "Sistemski",
        "theme.light": "Svetlo",
        "theme.dark": "Tamno",
        "settings.pressFeedback": "Zasvetli taster pri pritisku",
        "settings.poll": "Provera aplikacije",
        "settings.poll.help": "Koliko često se pita macOS koja je aplikacija u fokusu",
        "settings.startup": "Pokreni pri prijavi",
        "settings.permission": "Dozvola za prečice",
        "settings.permission.ok": "Odobrena",
        "settings.permission.missing": "Nije odobrena — tasteri sa prečicama neće raditi",
        "settings.permission.open": "Otvori podešavanja",
        "settings.config": "Konfiguracioni fajl",
        "settings.config.reveal": "Prikaži u Finder-u",

        "status.connected": "Povezano",
        "status.disconnected": "Servis nije pokrenut",
        "status.front": "U fokusu",
        "status.scene": "Scena",
        "status.unsaved": "Nesačuvane izmene",
        "status.save": "Sačuvaj",
        "status.revert": "Vrati",
        "status.saved": "Sačuvano",

        "menu.open": "Otvori Pult",
        "menu.quit": "Izađi",
        "error.title": "Nešto nije u redu",
    ]
}

extension L10n {
    var languageBinding: Binding<Language> {
        Binding(get: { self.language }, set: { self.language = $0 })
    }
}

/// How the app follows, or overrides, the system's appearance.
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }
    var label: String { T("theme.\(rawValue)") }
    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// The app's own settings, the ones that are about this window rather than
/// about the dock, and so do not belong in the daemon's configuration file.
final class Theme: ObservableObject {
    static let shared = Theme()

    @Published var appearance: Appearance {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "appearance") }
    }

    private init() {
        let stored = UserDefaults.standard.string(forKey: "appearance") ?? ""
        appearance = Appearance(rawValue: stored) ?? .system
    }
}

/// Short alias, so views read as text rather than lookups.
func T(_ key: String) -> String { L10n.shared(key) }
