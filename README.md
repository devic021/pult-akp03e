# akp03-deck

Per-application scene switching for the **Ajazz AKP03E** stream dock on macOS.

Point it at a config, leave it running: when you switch apps, the six keys
repaint and the encoders rebind. The dock stores nothing — every scene lives
here and is pushed over HID.

```
macOS frontmost app  →  bundle ID  →  scene  →  6 × JPEG 60×60 + action table
```

## Hardware

| | |
|---|---|
| Model | Ajazz AKP03E (`0300:3002`, Mirabox protocol v2) |
| Keys with displays | 6, laid out 2×3, JPEG 60×60 |
| Keys without displays | 3 |
| Encoders | 3, each CW / CCW / press |
| Boot logo | 320×240, the only thing stored on the device |

Indices, confirmed by pressing every control on the hardware:

```
        keys 0 1 2          encoder 1  (big knob, top)
             3 4 5

     buttons 6 7 8          encoder 0      encoder 2
             (round, no display)   (small knobs, bottom)
```

Each encoder reports a twist in either direction and a press of its own.

## Build and run

```sh
cargo build --release
./target/release/akp03-deck            # writes a starter config on first run
./target/release/akp03-deck my.toml    # or name one
```

First run creates `~/.config/akp03-deck/config.toml` from
[`config.example.toml`](config.example.toml). Edits are picked up while it runs;
a config that fails to parse is reported and the running one is kept.

## Permissions

Nothing is needed to drive the dock, and nothing is needed to see which app is
in front. The one exception is `shortcut` actions: sending a keystroke needs
**System Settings > Privacy & Security > Accessibility**.

On startup the daemon checks whether it is trusted and, if not, asks macOS to
show its own dialog — the app named there is the one to tick, which is not
necessarily this binary (see above). `run` and `volume` actions work without
any of this.

Two things that bite:

* An **unsigned** binary is trusted by its contents, so every rebuild looks
  like a different program and the grant quietly stops applying.
  [`scripts/sign.sh`](scripts/sign.sh) signs it with a local certificate it
  creates once, which makes the grant stick across rebuilds.
  `scripts/install.sh` runs it for you.
* Granting it to a terminal or editor hands that app control of the whole
  machine. Running as a login agent keeps the grant on `akp03-deck` alone.

On macOS 27 this list is **System Settings > Privacy & Security > Device
Control and Data Access**; it was called Accessibility before.

## Configuration

```toml
brightness = 70        # 0-100
poll_ms = 300          # how often to ask which app is in front
default = "general"    # scene when no other scene claims the app

[scenes.browser]
apps = ["com.google.Chrome", "com.apple.Safari"]   # trailing * matches a prefix

keys = [                                            # six, in reading order
  { label = "New tab", color = "#1f6feb", shortcut = "cmd+t" },
  { label = "Close",   color = "#d93025", shortcut = "cmd+w" },
]

buttons = [ { run = "open -a Finder" } ]            # the three without displays

encoders = [                                        # left to right
  { cw = { volume = 5 }, ccw = { volume = -5 }, press = { shortcut = "f8" } },
]
```

A key carries at most one action:

| | |
|---|---|
| `run = "shell command"` | runs it detached |
| `shortcut = "cmd+shift+4"` | sends a keystroke (needs Accessibility) |
| `volume = -5` | changes output volume by that many points |
| `scene = "other"` | switches scene by hand, until the frontmost app changes |
| `page = "next"` | turns to another page of the same scene (`next`, `prev`, `first`) |

### Pages

A scene may list more keys than the dock has. They are shown a page at a time,
and anything bound to `page` turns them; paging wraps around, so a knob never
hits a dead stop. The page resets whenever the scene changes, so an app always
comes up on its first page.

With more than one page, every key carries a hairline along its top edge split
into one segment per page, the current one lit. Putting it on all six keys
rather than one means it reads as a single strip across the dock, and it cannot
land on a key that a short last page leaves empty.

The shipped configuration gives every scene the same knobs, so the habit
carries between apps:

| | |
|---|---|
| small left | page through the scene, press for page one |
| big | whatever that app's main dial should be — timeline, tabs, messages |
| small right | output volume, press to mute |

Key art is `label`, `color` (`#RGB` or `#RRGGBB`), `text_color` (defaults to
whichever of black/white reads better), `icon`, `icon_color` and `animate`.
Labels shrink and wrap on their own.

### Icons

`icon` takes the name of a bundled icon, or a path to an SVG or image of your
own. The bundled set is [Lucide](https://lucide.dev) (ISC, see
`assets/icons/LICENSE`), compiled into the binary so the daemon does not depend
on where it was installed from. SVGs are recoloured to `icon_color` and
rasterised at the key's own resolution, so they stay sharp.

An icon name that is neither bundled nor a file fails at config load, with the
full list of bundled names in the error.

### Animation

`animate` gives a key movement while its scene is showing:

| | |
|---|---|
| `pulse` | the icon breathes — draws the eye without nagging |
| `spin` | the icon turns — for anything that means "working" |
| `blink` | the background flashes — for "live" or "careful" |

Frames go out at 15 fps, and only keys that actually move are redrawn. A dock
with nothing animated sends nothing at all: the clock only runs when there is
something to show. Measured on the hardware, one key costs 1.2 ms to send and
a full six-key repaint 5.2 ms, so a moving scene uses a few percent of what the
device can take. `cargo run --release --bin bench` re-measures it.

Pressing a key lights it briefly, which is independent of `animate` and can be
turned off with `press_feedback = false`.

Find an app's bundle ID:

```sh
lsappinfo info -only bundleid "$(lsappinfo front)"
```

## Tools

```sh
cargo run --bin preview -- chrome:2 out.png   # render a scene's page to a PNG, no dock needed
cargo run --bin bench                        # how fast the dock accepts images
cargo run --bin probe                        # print geometry, then watch key/encoder events
cargo run --bin probe -- --raw               # hex dump of raw HID input
cargo run --bin opentest                     # which HID interface can be opened
```

## Running it in the background

```sh
scripts/install.sh
```

That builds it, copies the binary to `~/.local/bin`, installs the config if
there is none, and loads `launchd/dev.akp03-deck.plist` as a login agent. Logs
land in `~/Library/Logs/akp03-deck.log`.

```sh
launchctl kickstart -k gui/$(id -u)/dev.akp03-deck   # restart it
launchctl bootout gui/$(id -u)/dev.akp03-deck        # stop it
```

Run it under `launchd` rather than from a terminal if you use `shortcut` keys.
macOS grants Accessibility to the process it holds *responsible*, which for
anything started from a terminal is the terminal — or the editor behind it. As
a login agent the binary is responsible for itself, so the permission lands on
`akp03-deck` and stays there.

## Two things worth knowing

**Why the frontmost app is read with `lsappinfo`.** The obvious call,
`NSWorkspace.frontmostApplication`, goes stale in a background process. That is
the root cause of app-based profile switching not working on macOS in OpenDeck
(issue #455, closed as *not planned*) and its upstream library
(`active-win-pos-rs` #49, still open). `lsappinfo` asks the launch services
daemon instead, stays correct from the background, and needs no permissions.

**Why `vendor/ajazz-sdk` exists.** The dock exposes its vendor pipe *and* a
plain keyboard under one VID/PID/serial. `ajazz-sdk` connects by serial, so it
can land on the keyboard interface, which macOS refuses without Input
Monitoring — `connect()` fails with `(0xE00002C1) privilege violation`. The
vendored copy adds one function, `Ajazz::connect_path`, so we open the vendor
pipe by path. See [`vendor/ajazz-sdk/PATCHES.md`](vendor/ajazz-sdk/PATCHES.md).
