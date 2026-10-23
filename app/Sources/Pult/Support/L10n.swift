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

    /// The translation, or the text the caller already has.
    ///
    /// For strings that arrive from the daemon: the knob rows are built from
    /// what the daemon says it honours, and its own one-line descriptions are
    /// English. Translating them here when we can, and showing the daemon's
    /// own words when we cannot, means a knob added to the daemon shows up in
    /// the editor at once — in English until someone writes the Serbian, which
    /// is far better than it not showing up at all, or showing up as a key.
    func callAsFunction(_ key: String, or fallback: String) -> String {
        table[key] ?? Self.en[key] ?? fallback
    }

    static let en: [String: String] = [
        "rest.playlist.none": "No animations yet \u{2014} make one under Animations",
        "device.bootLogo.clear": "Remove",
        "device.bootLogo.clear.help": "Writes a black panel over it. The dock hands no picture back, so the one it came with cannot be restored \u{2014} this is what removing can mean.",
        "device.bootLogo.cleared": "Removed from the dock",
        "device.bootLogo.default": "Pult mark",
        "device.bootLogo.default.help": "Pult's own, drawn at the size the dock asked for.",
        "device.bootLogo.failed": "The picture could not be drawn.",
        "welcome.says": "Pult drives an Ajazz AKP03E from this Mac. Two things before it can: a small background service, and permission for it to press keys on your behalf.",
        "welcome.permission": "Let it press keys",
        "welcome.permission.says": "Keys bound to a shortcut need this. System Settings \u{203A} Privacy & Security \u{203A} Device Control and Data Access \u{2014} tick pultd there. It was called Accessibility before macOS 27.",
        "welcome.still": "Still nothing. Check that the dock is plugged in, then look at the log in Settings.",
        "service.install": "Start the background service",
        "service.install.help": "The dock is driven by a small service that runs in the background. It is inside this app; this sets it to start when you log in.",
        "service.install.go": "Start it",
        "service.repair": "The service points somewhere else",
        "service.repair.help": "It was set up for a copy of Pult at another path \u{2014} most likely this one was moved. Point it here instead.",
        "service.repair.go": "Point it here",
        "animations.new": "New animation",
        "animations.rename": "Rename",
        "animations.name": "Name",
        "section.effect": "Choose a motion",
        "section.trial": "On the dock",
        "section.knobs": "Settings for this motion",
        "section.own": "Or a file of your own",
        "surface.off": "Back to six keys",
        "surface.off.says": "Drops the drawing. The keys keep whatever they are bound to \u{2014} nothing about the bindings changes.",
        "surface.off.go": "Remove the drawing",
        "nav.animations": "Animations",
        "nav.feeds": "Feeds",
        "feeds.says": "A key can show a number that comes from somewhere else \u{2014} the weather, the air, anything that answers with JSON. The daemon fetches it on a schedule and the keys read it back through a template.",
        "feeds.none": "No feeds yet",
        "feeds.none.help": "Feeds are written in the configuration file, under [feeds]. The shipped example has two: the weather and the air quality, both open and neither needing an account.",
        "section.place": "Where the dock is",
        "feeds.place": "Coordinates",
        "feeds.place.help": "What fills {lat} and {lon} in a feed's address. Kept out of the configuration file on purpose: that file is round-tripped, backed up and pasted into bug reports, and a latitude and longitude are a home address.",
        "feeds.place.lat": "Latitude",
        "feeds.place.lon": "Longitude",
        "feeds.place.save": "Save",
        "feeds.place.find": "Find me",
        "feeds.place.find.help": "Asks macOS once, to about a kilometre. You can type the numbers in instead and never grant anything.",
        "feeds.place.asking": "Asking\u{2026}",
        "feeds.place.denied": "macOS has not been allowed to share your location with Pult. System Settings > Privacy & Security > Location Services.",
        "feeds.place.failed": "No coordinates came back.",
        "feeds.place.unset": "Nothing has said where the dock is, so any feed whose address needs it cannot run.",
        "section.sources": "Sources",
        "feeds.every": "every",
        "feeds.check": "Check",
        "feeds.checking": "Checking\u{2026}",
        "feeds.age.never": "has never answered",
        "feeds.age.ago": "ago",
        "feeds.health.fresh": "Fresh",
        "feeds.health.stale": "Stale",
        "feeds.health.silent": "Silent",
        "feeds.health.failing": "Failing",
        "feeds.health.stale.help": "The last answer is older than this feed trusts. Its number is still on the dock, dimmed, with its age in place of its caption.",
        "feeds.fields": "What it brings back",
        "feeds.fields.help": "These are the names a key reads. Click one to copy the template that shows it.",
        "feeds.series": "hourly",
        "feeds.copied": "Copied",
        "feeds.hour": "The dock is reading",
        "feeds.hour.ahead": "hours ahead",
        "key.reads": "Reading",
        "key.reads.says": "A key that reports a number instead of doing something. Pressing it moves to the next reading rather than firing an action \u{2014} a key can only do one of the two.",
        "key.value": "Value",
        "key.value.help": "Written as a template: {vreme.temp|round}\u{b0}. Three glyphs fit comfortably, five fit, six never do \u{2014} so a percent sign belongs in the caption.",
        "key.caption": "Caption",
        "key.caption.help": "The small line under the number, saying what the number is. When the feed goes stale this is replaced by how old the reading is.",
        "key.cycle": "On press",
        "key.cycle.help": "The other things this key can show. Each press moves to the next and repaints that one key.",
        "key.cycle.add": "Add a reading",
        "key.cycle.remove": "Remove",
        "key.cycle.first": "At rest",
        "key.ramp": "Colour by value",
        "key.ramp.help": "Makes the background itself a reading. Between two stops the colour is mixed; past either end it holds.",
        "key.ramp.field": "Reads",
        "key.ramp.add": "Add a stop",
        "key.ramp.off": "No colour",
        "key.iconRotate": "Turn the icon",
        "key.iconRotate.help": "Degrees, or a template \u{2014} {vreme.bearing|compass16} points an arrow at the wind.",
        "action.hour": "Forecast",
        "action.hour.next": "Later",
        "action.hour.prev": "Earlier",
        "action.hour.now": "Now",
        "action.hour.help": "Moves the whole scene through the forecast. It comes back to now on its own after twenty seconds, so a dock left hours ahead cannot quietly show the wrong weather.",
        "nav.screensaver": "Screensaver",
        "animations.says": "One drawing across the whole dock instead of six separate pictures. The seams are real \u{2014} about a quarter of a key of plastic between each screen \u{2014} so these are sweeps, fields and fires, never text or photographs.",
        "animations.none": "Choose a scene to give it a drawing.",
        "rest.says": "What the dock does once you have stopped using it. Nothing here keeps the Mac awake: the dock asks to paint one last frame before sleep, then lets go.",
        "rest.when": "When it rests",
        "rest.what": "What it shows",
        "rest.light": "Light",
        "rest.on": "Rest the dock when the Mac is idle",
        "rest.on.says": "It stops being a controller and becomes something to look at. The keys still work.",
        "rest.after": "After",
        "rest.after.says": "Since the last keystroke or pointer move. A press on the dock counts too \u{2014} macOS never sees those, so the daemon folds them in itself.",
        "rest.wake": "Woken by",
        "rest.wake.says": "Only the dock, when you are reading a second screen and would rather it kept painting.",
        "rest.swallow": "Swallow the waking press",
        "rest.swallow.says": "Slapping a key to wake the dock should not also fire what that key does.",
        "rest.playlist": "Animations it cycles through",
        "rest.playlist.says": "Each is a whole scene, so each keeps its own motion, colours, geometry and frame rate. Only drawings are offered \u{2014} a page of labelled keys is a controller, not something to look at from across the room.",
        "rest.playlist.add": "Add an animation",
        "rest.playlist.missing": "not defined",
        "rest.hold": "Each one runs for",
        "rest.hold.says": "Five minutes is long enough to stop feeling like a slideshow.",
        "rest.fade": "Dissolve between them",
        "rest.fade.says": "A hard cut in the corner of your eye reads as a fault, so this is not zero by default.",
        "rest.fadein": "Come up over",
        "rest.fadein.says": "So it arrives instead of appearing.",
        "rest.brightness": "Resting brightness",
        "rest.brightness.says": "Dimmer than working, and never at the bottom: the backlight shifts colour down there.",
        "rest.dark": "Go dark with the display",
        "rest.dark.says": "Off by default: the point of a resting screen is that it keeps running when you look away.",
        "rest.sleepimage": "While the Mac sleeps",
        "rest.sleepimage.says": "One still picture, PNG or JPEG, across all six keys. Nothing can animate then \u{2014} the daemon is frozen with everything else.",
        "option.any": "Anything",
        "option.dock": "Only the dock",
        // --- the surface panel. Effect and knob names are deliberately absent
        // from this table: the daemon sends its own English for them, and
        // `T(key, or:)` falls through to it, so an effect added to the daemon
        // appears here at once instead of waiting for a line to be written.
        "section.surface": "What this scene paints",
        "surface.whole": "One drawing across the whole dock",
        "surface.whole.says": "Instead of six separate pictures. The keys keep whatever they are bound to \u{2014} a canvas replaces the picture, not the press.",
        "surface.try": "Show it on the dock",
        "surface.try.says": "The seams are the whole question, and no picture of a dock answers it. The trial ends on its own.",
        "surface.try.go": "Try it",
        "surface.try.stop": "Stop",
        "surface.try.failed": "The dock would not take the trial.",
        "surface.file": "A file of your own",
        "surface.file.says": "A GIF, an animated PNG or WebP, a folder of numbered frames, or one still picture.",
        "surface.file.choose": "Choose\u{2026}",
        "surface.file.drop": "Remove",
        "knob.clear": "Back to the default",
        "knob.own": "the effect decides",
        "yes": "Yes",
        "no": "No",
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
        "settings.look": "Look",
        "settings.behaviour": "Behaviour",
        "settings.files": "Files and permissions",
        "settings.config.short": "Configuration",
        "settings.log.short": "Log",
        "settings.tab.look": "Appearance",
        "settings.tab.behaviour": "Behaviour",
        "settings.tab.service": "Service",
        "settings.tab.about": "About",
        "settings.pressFeedback.short": "Light up on press",
        "settings.poll.short": "App check",
        "settings.intro": "How the app looks and behaves, and the background service that drives the dock.",
        "device.intro": "What the dock itself holds. Everything else — scenes, keys, actions — lives on this Mac.",
        "sidebar.setup": "Setup",
        "settings.theme.help": "Follow the system, or hold the window light or dark.",
        "settings.language.help": "Serbian and English. The system option follows your Mac.",
        "settings.pressFeedback.help": "A key lights up for a moment when you press it, so you can see the dock received it.",
        "settings.export": "Configuration file",
        "settings.export.help": "Every scene, key and binding lives in one readable file. Copy it to another Mac and the dock behaves the same.",
        "settings.export.save": "Export…",
        "settings.export.load": "Import…",
        "settings.export.done": "Exported",
        "settings.export.loaded": "Imported",
        "settings.stats": "What is set up",
        "settings.stats.help": "Across every scene in the configuration.",
        "stats.scenes": "scenes",
        "stats.keys": "keys bound",
        "stats.apps": "applications covered",
        "stats.icons": "icons available",
        "settings.socket": "Control socket",
        "settings.socket.help": "The app asks the daemon over this socket; only the daemon ever touches the dock.",
        "section.look": "Appearance",
        "section.behaviour": "Behaviour",
        "section.service": "Background service",
        "section.files": "Files and permissions",
        "section.overview": "Overview",
        "section.about": "About",
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
        "rest.playlist.none": "Jo\u{161} nema animacija \u{2014} napravi je pod Animacije",
        "device.bootLogo.clear": "Ukloni",
        "device.bootLogo.clear.help": "Upisuje crnu povr\u{161}inu preko. Dok ne vra\u{107}a nikakvu sliku nazad, pa se fabri\u{10d}ka ne mo\u{17e}e povratiti \u{2014} ovo je ono \u{161}to uklanjanje mo\u{17e}e da zna\u{10d}i.",
        "device.bootLogo.cleared": "Uklonjeno sa ure\u{111}aja",
        "device.bootLogo.default": "Pult znak",
        "device.bootLogo.default.help": "Pultov sopstveni, nacrtan u veli\u{10d}ini koju je dok tra\u{17e}io.",
        "device.bootLogo.failed": "Slika nije mogla da se nacrta.",
        "welcome.says": "Pult vodi Ajazz AKP03E sa ovog Mac-a. Dve stvari pre nego \u{161}to mo\u{17e}e: mali pozadinski servis, i dozvola da u tvoje ime pritiska tastere.",
        "welcome.permission": "Dozvoli mu da pritiska tastere",
        "welcome.permission.says": "Tasteri vezani za pre\u{10d}icu ovo tra\u{17e}e. Pode\u{161}avanja sistema \u{203A} Privatnost i bezbednost \u{203A} Kontrola ure\u{111}aja i pristup podacima \u{2014} \u{10d}ekiraj pultd tamo. Pre macOS 27 se zvalo Pristupa\u{10d}nost.",
        "welcome.still": "I dalje ni\u{161}ta. Proveri da li je dok priklju\u{10d}en, pa pogledaj dnevnik u Pode\u{161}avanjima.",
        "service.install": "Pokreni pozadinski servis",
        "service.install.help": "Dok vodi mali servis koji radi u pozadini. Nalazi se unutar ove aplikacije; ovim ga name\u{161}ta\u{161} da se pokre\u{107}e pri prijavi.",
        "service.install.go": "Pokreni",
        "service.repair": "Servis pokazuje na drugo mesto",
        "service.repair.help": "Name\u{161}ten je za kopiju Pulta na drugoj putanji \u{2014} najverovatnije je ova premesena. Usmeri ga ovde.",
        "service.repair.go": "Usmeri ovde",
        "animations.new": "Nova animacija",
        "animations.rename": "Preimenuj",
        "animations.name": "Naziv",
        "section.effect": "Izaberi pokret",
        "section.trial": "Na doku",
        "section.knobs": "Pode\u{161}avanja ovog pokreta",
        "section.own": "Ili sopstveni fajl",
        "surface.off": "Nazad na \u{161}est tastera",
        "surface.off.says": "Uklanja crte\u{17e}. Tasteri zadr\u{17e}avaju ono \u{161}to im je dodeljeno \u{2014} ni\u{161}ta se o dodelama ne menja.",
        "surface.off.go": "Ukloni crte\u{17e}",
        "nav.animations": "Animacije",
        "nav.feeds": "Dovodi",
        "feeds.says": "Taster mo\u{17e}e da prika\u{17e}e broj koji dolazi sa strane \u{2014} vreme, vazduh, bilo \u{161}ta \u{161}to odgovara JSON-om. Daemon ga preuzima po rasporedu, a tasteri ga \u{10d}itaju kroz \u{161}ablon.",
        "feeds.none": "Jo\u{161} nema dovoda",
        "feeds.none.help": "Dovodi se pi\u{161}u u konfiguracionom fajlu, pod [feeds]. Primer koji ide uz aplikaciju ima dva: vreme i kvalitet vazduha, oba otvorena i nijedan ne tra\u{17e}i nalog.",
        "section.place": "Gde je dok",
        "feeds.place": "Koordinate",
        "feeds.place.help": "Ono \u{161}to popunjava {lat} i {lon} u adresi dovoda. Namerno nije u konfiguracionom fajlu: taj fajl se stalno prepisuje, pravi mu se rezervna kopija i lepi se u prijave gre\u{161}aka, a geografska \u{161}irina i du\u{17e}ina su ku\u{107}na adresa.",
        "feeds.place.lat": "\u{160}irina",
        "feeds.place.lon": "Du\u{17e}ina",
        "feeds.place.save": "Sa\u{10d}uvaj",
        "feeds.place.find": "Prona\u{111}i me",
        "feeds.place.find.help": "Pita macOS jednom, na oko kilometar ta\u{10d}nosti. Mo\u{17e}e\u{161} i ru\u{10d}no da upi\u{161}e\u{161} brojeve i ne odobri\u{161} ni\u{161}ta.",
        "feeds.place.asking": "Pitam\u{2026}",
        "feeds.place.denied": "macOS nije dozvolio Pultu pristup lokaciji. Sistemska pode\u{161}avanja > Privatnost i bezbednost > Usluge lokacije.",
        "feeds.place.failed": "Koordinate nisu stigle.",
        "feeds.place.unset": "Niko nije rekao gde je dok, pa dovod kome adresa to tra\u{17e}i ne mo\u{17e}e da radi.",
        "section.sources": "Izvori",
        "feeds.every": "na svakih",
        "feeds.check": "Proveri",
        "feeds.checking": "Proveravam\u{2026}",
        "feeds.age.never": "nijednom se nije javio",
        "feeds.age.ago": "ranije",
        "feeds.health.fresh": "Sve\u{17e}e",
        "feeds.health.stale": "Ustajalo",
        "feeds.health.silent": "\u{106}uti",
        "feeds.health.failing": "Gre\u{161}ka",
        "feeds.health.stale.help": "Poslednji odgovor je stariji nego \u{161}to ovaj dovod veruje. Broj je i dalje na doku, prigu\u{161}en, a umesto opisa stoji koliko je star.",
        "feeds.fields": "\u{160}ta donosi",
        "feeds.fields.help": "Ovo su imena koja taster \u{10d}ita. Klikni na neko da kopira\u{161} \u{161}ablon koji ga prikazuje.",
        "feeds.series": "po satu",
        "feeds.copied": "Kopirano",
        "feeds.hour": "Dok \u{10d}ita",
        "feeds.hour.ahead": "sati unapred",
        "key.reads": "O\u{10d}itavanje",
        "key.reads.says": "Taster koji prikazuje broj umesto da ne\u{161}to uradi. Pritisak prelazi na slede\u{107}e o\u{10d}itavanje umesto da pokrene radnju \u{2014} taster mo\u{17e}e samo jedno od to dvoje.",
        "key.value": "Vrednost",
        "key.value.help": "Pi\u{161}e se kao \u{161}ablon: {vreme.temp|round}\u{b0}. Tri znaka staju udobno, pet staje, \u{161}est nikad \u{2014} pa znak procenta ide u opis.",
        "key.caption": "Opis",
        "key.caption.help": "Mali red ispod broja, koji ka\u{17e}e \u{161}ta je taj broj. Kada dovod ustaja, umesto opisa stoji koliko je o\u{10d}itavanje staro.",
        "key.cycle": "Na pritisak",
        "key.cycle.help": "Ostale stvari koje ovaj taster mo\u{17e}e da prika\u{17e}e. Svaki pritisak prelazi na slede\u{107}u i preiscrtava samo taj taster.",
        "key.cycle.add": "Dodaj o\u{10d}itavanje",
        "key.cycle.remove": "Ukloni",
        "key.cycle.first": "U mirovanju",
        "key.ramp": "Boja po vrednosti",
        "key.ramp.help": "\u{10c}ini pozadinu samim o\u{10d}itavanjem. Izme\u{111}u dve ta\u{10d}ke boja se me\u{161}a; iza krajeva se zadr\u{17e}ava.",
        "key.ramp.field": "\u{10c}ita",
        "key.ramp.add": "Dodaj ta\u{10d}ku",
        "key.ramp.off": "Bez boje",
        "key.iconRotate": "Okreni ikonu",
        "key.iconRotate.help": "Stepeni, ili \u{161}ablon \u{2014} {vreme.bearing|compass16} okre\u{107}e strelicu ka vetru.",
        "action.hour": "Prognoza",
        "action.hour.next": "Kasnije",
        "action.hour.prev": "Ranije",
        "action.hour.now": "Sada",
        "action.hour.help": "Pomera celu scenu kroz prognozu. Sama se vra\u{107}a na sada posle dvadeset sekundi, da dok ostavljen satima unapred ne bi tiho prikazivao pogre\u{161}no vreme.",
        "nav.screensaver": "\u{10c}uvar ekrana",
        "animations.says": "Jedan crte\u{17e} preko celog doka umesto \u{161}est odvojenih slika. \u{160}avovi su stvarni \u{2014} oko \u{10d}etvrtine tastera plastike izme\u{111}u svaka dva ekrana \u{2014} pa su ovo preleti, polja i vatre, nikad tekst ni fotografije.",
        "animations.none": "Izaberi scenu da joj da\u{161} crte\u{17e}.",
        "rest.says": "\u{160}ta dok radi kada prestane\u{161} da ga koristi\u{161}. Ni\u{161}ta ovde ne spre\u{10d}ava Mac da zaspi: dok tra\u{17e}i da nacrta jo\u{161} jedan frejm pre spavanja, pa pu\u{161}ta.",
        "rest.when": "Kada se smiruje",
        "rest.what": "\u{160}ta prikazuje",
        "rest.light": "Svetlo",
        "rest.on": "Smiri dok kada Mac miruje",
        "rest.on.says": "Prestaje da bude kontroler i postaje ne\u{161}to za gledanje. Tasteri i dalje rade.",
        "rest.after": "Posle",
        "rest.after.says": "Od poslednjeg pritiska tastera ili pomeraja mi\u{161}a. Pritisak na doku se tako\u{111}e ra\u{10d}una \u{2014} macOS ih ne vidi, pa ih daemon sam ura\u{10d}unava.",
        "rest.wake": "Budi ga",
        "rest.wake.says": "Samo dok, kada \u{10d}ita\u{161} drugi ekran i radije bi da nastavi da crta.",
        "rest.swallow": "Progutaj pritisak koji budi",
        "rest.swallow.says": "Udarac po tasteru da probudi\u{161} dok ne sme da pokrene i ono \u{161}to taj taster radi.",
        "rest.playlist": "Animacije kroz koje kru\u{17e}i",
        "rest.playlist.says": "Svaka je cela scena, pa svaka zadr\u{17e}ava svoj pokret, boje, geometriju i broj frejmova. Nude se samo crte\u{17e}i \u{2014} strana sa obele\u{17e}enim tasterima je kontroler, a ne ne\u{161}to \u{161}to se gleda iz daljine.",
        "rest.playlist.add": "Dodaj animaciju",
        "rest.playlist.missing": "nije definisana",
        "rest.hold": "Svaka traje",
        "rest.hold.says": "Pet minuta je dovoljno dugo da prestane da li\u{10d}i na slajd\u{161}ou.",
        "rest.fade": "Pretapanje izme\u{111}u njih",
        "rest.fade.says": "O\u{161}tar rez u uglu oka deluje kao kvar, zato podrazumevano nije nula.",
        "rest.fadein": "Pojavljuje se za",
        "rest.fadein.says": "Da stigne, umesto da se pojavi.",
        "rest.brightness": "Osvetljenje u mirovanju",
        "rest.brightness.says": "Tamnije nego u radu, ali nikad na dnu: tamo se boja pozadinskog svetla menja.",
        "rest.dark": "Ugasi se sa ekranom",
        "rest.dark.says": "Podrazumevano isklju\u{10d}eno: poenta ekrana u mirovanju je da nastavi dok ne gleda\u{161}.",
        "rest.sleepimage": "Dok Mac spava",
        "rest.sleepimage.says": "Jedna mirna slika, PNG ili JPEG, preko svih \u{161}est tastera. Tada ni\u{161}ta ne mo\u{17e}e da se animira \u{2014} daemon je zamrznut sa svim ostalim.",
        "option.any": "Bilo \u{161}ta",
        "option.dock": "Samo dok",
        // --- platno
        "section.surface": "\u{160}ta ova scena crta",
        "surface.whole": "Jedan crte\u{17e} preko celog doka",
        "surface.whole.says": "Umesto \u{161}est odvojenih slika. Tasteri zadr\u{17e}avaju ono \u{161}to im je dodeljeno \u{2014} platno menja sliku, ne pritisak.",
        "surface.try": "Prika\u{17e}i na doku",
        "surface.try.says": "\u{160}avovi su celo pitanje, a nijedna slika doka na njega ne odgovara. Proba se sama zavr\u{161}ava.",
        "surface.try.go": "Probaj",
        "surface.try.stop": "Zaustavi",
        "surface.try.failed": "Dok nije prihvatio probu.",
        "surface.file": "Sopstveni fajl",
        "surface.file.says": "GIF, animirani PNG ili WebP, folder numerisanih frejmova, ili jedna slika.",
        "surface.file.choose": "Izaberi\u{2026}",
        "surface.file.drop": "Ukloni",
        "knob.clear": "Nazad na podrazumevano",
        "knob.own": "efekat odlu\u{10d}uje",
        "yes": "Da",
        "no": "Ne",

        // --- efekti
        "effect.sweep": "Prelet",
        "effect.sweep.says": "Traka svetla pre\u{17e}e preko doka i vra\u{107}a se iznova.",
        "effect.wave": "Talas",
        "effect.wave.says": "Putuju\u{107}i talas, kao svetao greben ili kao te\u{10d}nost u rezervoaru.",
        "effect.pulse": "Puls",
        "effect.pulse.says": "Prstenovi napu\u{161}taju ta\u{10d}ku i blede dok se \u{161}ire.",
        "effect.rain": "Ki\u{161}a",
        "effect.rain.says": "Potezi padaju svaki svojom brzinom, naginju se sa vetrom.",
        "effect.aurora": "Zora",
        "effect.aurora.says": "Sporo polje boje, bez i\u{10d}ega \u{161}to bi oko pratilo.",
        "effect.orbit": "Orbita",
        "effect.orbit.says": "Svetla glava tr\u{10d}i zatvorenu putanju i vu\u{10d}e sopstveno zamu\u{107}enje.",
        "effect.warp": "Skok",
        "effect.warp.says": "Ta\u{10d}ke jure iz sredine i izdu\u{17e}uju se dok lete.",
        "effect.lava": "Lava",
        "effect.lava.says": "Meke mase lutaju, spajaju se vratom i stapaju.",
        "effect.ember": "Vatra",
        "effect.ember.says": "Plamen se penje sa jedne ivice i cepa se u jezike.",
        "effect.breathe": "Dah",
        "effect.breathe.says": "Ceo dok se \u{161}iri i bledi kao jedna lampa.",

        // --- klizači
        "knob.speed": "Brzina",
        "knob.speed.says": "Koliko brzo se kre\u{107}e. Promena nikad ne natera sliku da posko\u{10d}i.",
        "knob.direction": "Smer",
        "knob.direction.says": "Kuda putuje. Nepode\u{161}eno zna\u{10d}i sopstvena osa efekta.",
        "knob.cycle": "Kraj petlje",
        "knob.cycle.says": "Kreni ispo\u{10d}etka sa druge strane, ili se okreni i vrati.",
        "knob.scale": "Veli\u{10d}ina",
        "knob.scale.says": "Mno\u{17e}i svaku du\u{17e}inu. Ovo odlu\u{10d}uje da li je ne\u{161}to \u{161}ire od \u{161}ava.",
        "knob.density": "Koli\u{10d}ina",
        "knob.density.says": "Koliko ih ima: traka, prstenova, poteza, zvezda, masa.",
        "knob.softness": "Mek\u{107}a ivica",
        "knob.softness.says": "O\u{161}tra ivica na nuli, rastopljena preko cele \u{161}irine na jedinici.",
        "knob.origin": "Odakle",
        "knob.origin.says": "Sredina je centar \u{161}ava, pa prsten sti\u{17e}e ve\u{107} \u{161}irok \u{161}esnaest piksela.",
        "knob.color": "Boja",
        "knob.color.says": "Najtopliji pikseli.",
        "knob.color2": "Druga boja",
        "knob.color2.says": "Nepode\u{161}ena je prva posvetljena, pa dve boje izgledaju namerno bez biranja.",
        "knob.background": "Pozadina",
        "knob.background.says": "Ispuna ispod svega. Skoro crna: prava crna pored osvetljene plastike deluje pokvareno.",
        "knob.color_cycle": "Smena boja",
        "knob.color_cycle.says": "Sekundi za jedan spor prelaz izme\u{111}u dve boje. Isklju\u{10d}eno na nuli.",
        "knob.opacity": "Ja\u{10d}ina",
        "knob.opacity.says": "Glavno stapanje. Nije pozadinsko osvetljenje.",
        "knob.seed": "Raspored",
        "knob.seed.says": "Druga\u{10d}iji raspored istog karaktera.",
        "knob.mapping": "Geometrija",
        "knob.mapping.says": "Fizi\u{10d}ka \u{10d}uva oblike preko procepa; zbijena \u{10d}uva stalnu brzinu fronta.",
        "knob.fps": "Frejmova u sekundi",
        "knob.fps.says": "Glatko\u{107}a ko\u{161}ta vremena na \u{17e}ici, ne zauzetog jezgra.",
        "knob.stop_after": "Smiri se posle",
        "knob.stop_after.says": "Zadr\u{17e}i poslednji frejm posle ovoliko, da scena u kojoj radi\u{161} ne odvla\u{10d}i pa\u{17e}nju. Nikad, na nuli.",
        "knob.reduce_motion": "Po\u{161}tuj manje pokreta",
        "knob.reduce_motion.says": "Nacrtaj jedan miran frejm kada macOS tra\u{17e}i manje pokreta.",
        "knob.shear": "Nagib",
        "knob.shear.says": "Naginje traku u dijagonalno brisanje.",
        "knob.fill": "Ispuna",
        "knob.fill.says": "Gola linija na nuli, te\u{10d}nost u rezervoaru na polovini.",
        "knob.bands": "Zavese",
        "knob.bands.says": "Glatko polje na nuli, meke zavese na tri do pet.",
        "knob.wind": "Vetar",
        "knob.wind.says": "Bo\u{10d}no skretanje. Preko oko \u{10d}etiri desetine koristi fizi\u{10d}ku, ili se nagib prelama na \u{161}avu.",
        "knob.lobes": "Re\u{17e}njevi",
        "knob.lobes.says": "Jedan i jedan elipsa, tri i dva \u{10d}vor, dva i jedan osmica.",
        "knob.trail": "Trag",
        "knob.trail.says": "Sekundi pro\u{161}losti koje se jo\u{161} crtaju. Na nuli glava pre\u{111}e \u{161}av nevidljivo.",
        "knob.exponent": "Perspektiva",
        "knob.exponent.says": "Lagano kretanje na jedinici, perspektiva na dva i po, nasilan skok na \u{10d}etiri.",
        "knob.threshold": "Prag spajanja",
        "knob.threshold.says": "Na jedinici masa se zavr\u{161}ava na svom polupre\u{10d}niku. Ni\u{17e}e i sve se stapa.",
        "knob.height": "Visina plamena",
        "knob.height.says": "Dokle se plamen penje uz dok.",
        "knob.smoke": "Dim",
        "knob.smoke.says": "Rastopi vrh u pozadinu.",
        "knob.shape": "Oblik daha",
        "knob.shape.says": "Koji dah.",
        "knob.floor": "Donji nivo",
        "knob.floor.says": "Nivo na dnu daha. Iznad nule, da dok nikad ne izgleda ugasen.",

        // --- vrednosti izbora
        "option.right": "desno",
        "option.left": "levo",
        "option.up": "gore",
        "option.down": "dole",
        "option.cw": "u smeru kazaljke",
        "option.ccw": "suprotno od kazaljke",
        "option.out": "spolja",
        "option.in": "unutra",
        "option.wrap": "u krug",
        "option.bounce": "napred-nazad",
        "option.physical": "fizi\u{10d}ka",
        "option.packed": "zbijena",
        "option.sine": "sinus",
        "option.ease": "ubla\u{17e}en",
        "option.heartbeat": "otkucaj srca",
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
        "settings.look": "Izgled",
        "settings.behaviour": "Ponašanje",
        "settings.files": "Datoteke i dozvole",
        "settings.config.short": "Konfiguracija",
        "settings.log.short": "Log",
        "settings.tab.look": "Izgled",
        "settings.tab.behaviour": "Ponašanje",
        "settings.tab.service": "Servis",
        "settings.tab.about": "O programu",
        "settings.pressFeedback.short": "Zasvetli pri pritisku",
        "settings.poll.short": "Provera aplikacije",
        "settings.intro": "Kako aplikacija izgleda i kako se ponaša, i pozadinski servis koji vodi dok.",
        "device.intro": "Ono što sam uređaj pamti. Sve ostalo — scene, tasteri, akcije — živi na ovom Mac-u.",
        "sidebar.setup": "Podešavanje",
        "settings.theme.help": "Prati sistem, ili drži prozor svetlim odnosno tamnim.",
        "settings.language.help": "Srpski i engleski. Sistemska opcija prati tvoj Mac.",
        "settings.pressFeedback.help": "Taster na trenutak zasvetli kad ga pritisneš, da vidiš da je dok primio pritisak.",
        "settings.export": "Konfiguracioni fajl",
        "settings.export.help": "Sve scene, tasteri i veze stoje u jednom čitljivom fajlu. Prenesi ga na drugi Mac i dok se ponaša isto.",
        "settings.export.save": "Izvezi…",
        "settings.export.load": "Uvezi…",
        "settings.export.done": "Izvezeno",
        "settings.export.loaded": "Uvezeno",
        "settings.stats": "Šta je podešeno",
        "settings.stats.help": "Zbirno kroz sve scene u konfiguraciji.",
        "stats.scenes": "scena",
        "stats.keys": "vezanih tastera",
        "stats.apps": "pokrivenih aplikacija",
        "stats.icons": "dostupnih ikona",
        "settings.socket": "Kontrolni socket",
        "settings.socket.help": "Aplikacija pita daemon preko ovog socket-a; dok dira isključivo daemon.",
        "section.look": "Izgled",
        "section.behaviour": "Ponašanje",
        "section.service": "Pozadinski servis",
        "section.files": "Datoteke i dozvole",
        "section.overview": "Pregled",
        "section.about": "O programu",
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

    /// What every text size in the app is multiplied by.
    var scale: CGFloat {
        switch self {
        case .small: return 0.88
        case .normal: return 1.0
        case .large: return 1.15
        case .larger: return 1.32
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

    /// Read by `Font.app(_:)`, which is why it is on the shared instance.
    var textScale: CGFloat { textSize.scale }

    private init() {
        let defaults = UserDefaults.standard
        appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        textSize = TextSize(rawValue: defaults.string(forKey: "textSize") ?? "") ?? .normal
    }
}

/// Short alias, so views read as text rather than lookups.
func T(_ key: String) -> String { L10n.shared(key) }
func T(_ key: String, or fallback: String) -> String { L10n.shared(key, or: fallback) }
