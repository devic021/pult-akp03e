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
final class L10n: ObservableObject {
    static let shared = L10n()

    @AppStorage("language") var language: Language = .system {
        willSet { objectWillChange.send() }
    }

    /// The language actually used, once `system` is resolved.
    var resolved: Language {
        if language != .system { return language }
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.hasPrefix("sr") || preferred.hasPrefix("hr") || preferred.hasPrefix("bs")
            ? .sr
            : .en
    }

    func callAsFunction(_ key: String) -> String {
        let table = resolved == .sr ? Self.sr : Self.en
        return table[key] ?? Self.en[key] ?? key
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

/// Short alias, so views read as text rather than lookups.
func T(_ key: String) -> String { L10n.shared(key) }
