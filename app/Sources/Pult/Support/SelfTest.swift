import Foundation

/// Checks the app against a running daemon and exits, printing what it found.
///
/// Decoding is the fragile seam: the daemon omits anything empty, and a missing
/// key that Swift insists on is a blank window with an unhelpful alert. This
/// catches that from a terminal, in a second, without a screenshot.
enum SelfTest {
    static func run() -> Never {
        let client = ControlClient()
        var failures: [String] = []

        do {
            let status = try client.send(["cmd": "status"], as: Status.self)
            print("status      : ok")
            print("  device    : \(status.device?.kind ?? "—") \(status.device?.firmware ?? "")")
            print("  scene     : \(status.scene ?? "—") page \((status.page ?? 0) + 1)/\(status.pages ?? 1)")
            print("  front     : \(status.app ?? "—")")
            print("  keystrokes: \(status.keystrokes_allowed == true ? "allowed" : "blocked")")
            if status.device == nil { failures.append("status carried no device") }
        } catch {
            failures.append("status: \(error.localizedDescription)")
        }

        do {
            let config = try client.send(["cmd": "config"], as: Config.self, field: "config")
            print("config      : ok, \(config.scenes.count) scenes, default \(config.defaultScene)")

            // Every scene has to survive the trip, not just the first one.
            for name in config.sceneNames {
                guard let scene = config.scenes[name] else { continue }
                let pages = scene.pages()
                print("  \(name.padding(toLength: 12, withPad: " ", startingAt: 0))"
                    + " \(scene.keys.count) keys / \(pages) page(s)"
                    + ", \(scene.encoders.count) knobs, \(scene.apps.count) apps")
            }
            if config.scenes.isEmpty { failures.append("config carried no scenes") }

            // And survive being sent back, which is what saving does.
            let encoded = try JSONEncoder().encode(config)
            let round = try JSONDecoder().decode(Config.self, from: encoded)
            if round != config { failures.append("config does not survive a round trip") }
            print("round trip  : ok")
        } catch {
            failures.append("config: \(error.localizedDescription)")
        }

        // A newer daemon will write keys this build has no field for. The app
        // must carry them through a save untouched, or the first edit from the
        // editor deletes them.
        do {
            // Every one of these is something a newer daemon, or a hand, could
            // have written and this build has no case for. `surface` used to be
            // one opaque blob and survived for free; now that it is typed, what
            // is at risk is a *knob* inside it — so that is what this asks
            // about. Same for the screensaver, typed in the same change.
            let sample = """
            {"brightness":70,"poll_ms":300,"press_feedback":true,"default":"general",
             "feeds":{"weather":{"kind":"http","every":900}},
             "idle":{"after":"3m","scene":"x","gravity":0.8},
             "scenes":{"x":{"surface":{"kind":"canvas","effect":"aurora","bands":4,"wobble":0.4},
                            "keys":[{"label":"a","value":"{weather.temp}"}]}}}
            """
            let decoded = try JSONDecoder().decode(Config.self, from: Data(sample.utf8))
            let again = try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(decoded)
            ) as? [String: Any] ?? [:]

            let scene = (again["scenes"] as? [String: Any])?["x"] as? [String: Any]
            let surface = scene?["surface"] as? [String: Any]
            let checks: [(String, Bool)] = [
                ("feeds", again["feeds"] != nil),
                ("surface", surface?["effect"] as? String == "aurora"),
                // A knob this build does know, read and written back as itself.
                ("knob", (surface?["bands"] as? NSNumber)?.intValue == 4),
                // And one it has never heard of, which must survive untouched.
                ("new knob", surface?["wobble"] != nil),
                ("idle", (again["idle"] as? [String: Any])?["gravity"] != nil),
                ("value", ((scene?["keys"] as? [[String: Any]])?.first)?["value"] != nil),
            ]

            print("unknown keys: "
                + checks.map { "\($0.0) \($0.1 ? "kept" : "LOST")" }.joined(separator: ", "))
            if checks.contains(where: { !$0.1 }) {
                failures.append("saving would delete configuration this build does not understand")
            }
        } catch {
            failures.append("unknown-key round trip: \(error.localizedDescription)")
        }

        do {
            let icons = try client.send(["cmd": "icons"], as: [String].self, field: "icons")
            print("icons       : ok, \(icons.count)")
            if icons.isEmpty { failures.append("no icons") }
        } catch {
            failures.append("icons: \(error.localizedDescription)")
        }

        do {
            let reply = try client.send(["cmd": "render_key", "size": 64, "key": ["label": "ok", "icon": "play"]])
            let png = (reply["png"] as? String).flatMap { Data(base64Encoded: $0) }
            print("render      : ok, \(png?.count ?? 0) bytes")
            if (png?.count ?? 0) == 0 { failures.append("render returned nothing") }
        } catch {
            failures.append("render: \(error.localizedDescription)")
        }

        print()
        if failures.isEmpty {
            print("all good")
            exit(0)
        }
        for failure in failures {
            print("FAILED: \(failure)")
        }
        exit(1)
    }
}
