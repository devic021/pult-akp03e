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
