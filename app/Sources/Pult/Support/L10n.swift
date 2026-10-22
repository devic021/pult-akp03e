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
        "help.label": "Text drawn on the key. It shrinks and wraps to fit.",
        "help.icon": "A bundled icon, or an image of your own. Drawn above the label.",
        "help.color": "The key's background.",
        "help.iconColor": "Leave unset to follow the label's colour.",
        "help.textColor": "Unset means black or white, whichever reads better on the background.",
        "help.animate": "Movement while this scene is on screen. Only animated keys are redrawn.",
        "help.action": "What happens when the key is pressed. A key carries one action.",
        "help.clear": "Empties the key: no art, no action.",
        "help.page": "Keys past the sixth live on further pages. Bind a knob to turn them.",
        "help.showScene": "Show this scene on the dock now, until the frontmost application changes.",
        "help.default": "Shown whenever no scene claims the application in front.",
        "help.apps": "Bundle IDs this scene claims. A trailing * matches a prefix.",
        "help.brightness": "Applied to the dock at once. Saved with the configuration.",
        "help.sleep": "Blanks the dock's displays until something wakes it.",
        "help.save": "Writes the configuration and reloads the dock.",
        "help.revert": "Throws away every change since the last save.",
        "hint.device": "Click a key, a knob or a button to set it up · drag a key to move it",
        "scene.menu": "Scene actions",
        "key.hint.drag": "Drag onto another key to swap them",
        "status.daemon": "Service",
        "status.device": "Dock",
        "help.connected": "The background service is running and holds the dock.",
        "help.disconnected": "The background service is not running, so the dock is not being driven.",
        "help.device": "The dock this Mac is talking to.",
        "help.front": "The application in front right now. It decides which scene the dock shows.",
        "help.activeScene": "The scene on the dock right now.",
        "bindings.title": "What this scene does",
        "bindings.open": "Overview",
        "close": "Close",
        "count.keys": "keys",
        "count.knobs": "knobs",
        "count.buttons": "buttons",
        "count.pages": "pages",
        "about.title": "About Pult",
        "about.version": "Version",
        "about.author": "Made by",
        "about.device": "Dock",
        "about.credits": "Built with",
        "service.title": "Background service",
        "service.running": "Running",
        "service.stopped": "Stopped",
        "service.login": "Start at login",
        "service.login.help": "Keeps the dock driven from the moment you log in. Turning it off stops it now and at login.",
        "service.restart": "Restart",
        "service.restart.help": "Stops and starts the service. The dock goes dark for a second.",
        "service.log": "Log",
        "service.log.open": "Open log",
        "about.summary": "Pult drives the dock from this Mac: it watches which application is in front and repaints the keys to match. The dock itself stores nothing but its boot logo.",
        "nav.scenes": "Scenes",
        "nav.device": "Device",
        "nav.settings": "Settings",
        "nav.about": "About",

        "scene.new": "New scene",
        "scene.delete": "Delete scene",
        "scene.rename": "Name",
        "scene.apps": "Applications",
        "scene.apps.help": "Bundle IDs this scene claims. A trailing * matches a prefix.",
        "scene.apps.add": "Add application",
        "scene.apps.intro": "Opening one of these applications switches the dock to this scene",
        "scene.apps.none": "No application claims this scene — it can only be reached by hand",
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
        "key.icon.choose": "Search icons…",
        "icon.count": "icons",
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
        "settings.textSize": "Text size",
        "settings.textSize.help": "Applies to the interface. The drawing of the dock keeps the hardware's proportions.",
        "text.small": "Small",
        "text.normal": "Default",
        "text.large": "Large",
        "text.larger": "Larger",
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
        "help.label": "Tekst na tasteru. Sam se smanjuje i prelama da stane.",
        "help.icon": "Ikona iz seta, ili tvoja slika. Crta se iznad natpisa.",
        "help.color": "Pozadina tastera.",
        "help.iconColor": "Ostavi prazno da prati boju natpisa.",
        "help.textColor": "Prazno znači crno ili belo, šta se bolje čita na pozadini.",
        "help.animate": "Kretanje dok je scena na ekranu. Prefarbavaju se samo animirani tasteri.",
        "help.action": "Šta se dešava na pritisak. Taster nosi jednu akciju.",
        "help.clear": "Prazni taster: bez slike i bez akcije.",
        "help.page": "Tasteri posle šestog idu na naredne strane. Veži točak da ih lista.",
        "help.showScene": "Prikaži ovu scenu na doku odmah, dok se ne promeni aplikacija u fokusu.",
        "help.default": "Prikazuje se kad nijedna scena ne preuzme aplikaciju u fokusu.",
        "help.apps": "Bundle ID-evi koje ova scena preuzima. Zvezdica na kraju hvata prefiks.",
        "help.brightness": "Primenjuje se na dok odmah. Čuva se uz konfiguraciju.",
        "help.sleep": "Gasi ekrane doka dok ga nešto ne probudi.",
        "help.save": "Upisuje konfiguraciju i osvežava dok.",
        "help.revert": "Odbacuje sve izmene od poslednjeg čuvanja.",
        "hint.device": "Klikni taster, točak ili dugme da ga podesiš · prevuci taster da ga premestiš",
        "scene.menu": "Radnje nad scenom",
        "key.hint.drag": "Prevuci na drugi taster da zamene mesta",
        "status.daemon": "Servis",
        "status.device": "Dok",
        "help.connected": "Pozadinski servis radi i drži uređaj.",
        "help.disconnected": "Pozadinski servis ne radi, pa dok niko ne vodi.",
        "help.device": "Uređaj sa kojim ovaj Mac priča.",
        "help.front": "Aplikacija koja je trenutno u fokusu. Ona bira koju scenu dok prikazuje.",
        "help.activeScene": "Scena koja je sada na doku.",
        "bindings.title": "Šta ova scena radi",
        "bindings.open": "Pregled",
        "close": "Zatvori",
        "count.keys": "tastera",
        "count.knobs": "točka",
        "count.buttons": "dugmadi",
        "count.pages": "strane",
        "about.title": "O programu",
        "about.version": "Verzija",
        "about.author": "Autor",
        "about.device": "Uređaj",
        "about.credits": "Izgrađeno uz",
        "service.title": "Pozadinski servis",
        "service.running": "Radi",
        "service.stopped": "Zaustavljen",
        "service.login": "Pokreni pri prijavi",
        "service.login.help": "Drži dok vođenim od trenutka prijave. Isključivanje ga zaustavlja i sada i pri prijavi.",
        "service.restart": "Restartuj",
        "service.restart.help": "Zaustavlja i ponovo pokreće servis. Dok se nakratko ugasi.",
        "service.log": "Log",
        "service.log.open": "Otvori log",
        "about.summary": "Pult vodi dok sa ovog Mac-a: prati koja je aplikacija u fokusu i prefarbava tastere u skladu sa tim. Sam uređaj ne pamti ništa osim logoa pri pokretanju.",
        "nav.scenes": "Scene",
        "nav.device": "Uređaj",
        "nav.settings": "Podešavanja",
        "nav.about": "O programu",

        "scene.new": "Nova scena",
        "scene.delete": "Obriši scenu",
        "scene.rename": "Naziv",
        "scene.apps": "Aplikacije",
        "scene.apps.help": "Bundle ID-evi koje ova scena preuzima. Zvezdica na kraju hvata prefiks.",
        "scene.apps.add": "Dodaj aplikaciju",
        "scene.apps.intro": "Kad otvoriš neku od ovih aplikacija, dok prelazi na ovu scenu",
        "scene.apps.none": "Nijedna aplikacija ne poziva ovu scenu — dostupna je samo ručno",
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
        "key.icon.choose": "Pretraži ikone…",
        "icon.count": "ikona",
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
        "settings.textSize": "Veličina teksta",
        "settings.textSize.help": "Odnosi se na interfejs. Crtež uređaja zadržava proporcije hardvera.",
        "text.small": "Sitno",
        "text.normal": "Podrazumevano",
        "text.large": "Krupno",
        "text.larger": "Krupnije",
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

/// How large the interface text is.
///
/// A deliberately short range: the window is a layout, not a document, and
/// sizes beyond this start pushing controls out of their rows. The drawing of
/// the dock is left out of it entirely — its proportions are the hardware's.
enum TextSize: String, CaseIterable, Identifiable {
    case small, normal, large, larger

    var id: String { rawValue }
    var label: String { T("text.\(rawValue)") }

    var dynamicTypeSize: DynamicTypeSize {
        switch self {
        case .small: return .small
        case .normal: return .medium
        case .large: return .large
        case .larger: return .xLarge
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

    @Published var textSize: TextSize {
        didSet { UserDefaults.standard.set(textSize.rawValue, forKey: "textSize") }
    }

    private init() {
        let defaults = UserDefaults.standard
        appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        textSize = TextSize(rawValue: defaults.string(forKey: "textSize") ?? "") ?? .normal
    }
}

/// Short alias, so views read as text rather than lookups.
func T(_ key: String) -> String { L10n.shared(key) }
