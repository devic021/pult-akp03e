# Changelog

All notable changes to Pult are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
follows [semantic versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.3] - 2026-11-14

### Fixed
- Idle sleep no longer stalls for thirty seconds. The daemon registers for
  system power events so it can paint a last frame before the Mac sleeps, but it
  never answered the `kIOMessageCanSystemSleep` query that macOS sends first, so
  every idle sleep waited out the full acknowledgement timeout. The daemon now
  allows that query at once. It still takes no power assertion and never keeps
  the Mac awake; it simply stops delaying the sleep it was always going to allow.

## [0.4.2] - 2026-11-12

### Changed
- A two-line key caption now stacks its lines and drops the leading icon, so a
  two-word label, and the readout a key shows while pressed, reads at a larger
  size.

### Documentation
- The README documents the Home Assistant data source and the source-rotation
  button.

## [0.4.1] - 2026-10-29

### Changed
- Rotating the data source from the dock no longer rewrites the config file on
  every press. The rotated source is live state that lasts until the daemon
  restarts, so an editor open on the same file no longer reads the change as an
  unsaved edit being overwritten.

## [0.4.0] - 2026-10-29

### Added
- Home Assistant is a first-class data source inside the Pult app: a connection
  pane for its URL and token (the token is kept in the Keychain), automatic
  detection of a local instance, and a setting that turns the first black button
  into a switch that rotates between data sources.
- Colour ramps on the control keys and multi-line readouts.

### Changed
- The daemon draws the dock exactly the way the editor previews it, and the
  renderer scales a key's text to fit the space it has.

## [0.3.0] - 2026-10-23

### Added
- Keys report live readouts: a value stands apart from its caption, a reading
  can be scrubbed forward with a knob, and a scene can be held on the dock.
- The machine reads its own vitals directly, with no helper process and no root.

### Changed
- The dock shows the system volume, and setting the volume no longer spawns a
  process. Mute has a picture of its own, and one speaker spans all six screens.
- Changing a feed is no longer undone by the next save.

## [0.2.0] - 2026-10-23

### Added
- A feed runtime and the templates a key reads it through, so the dock can show
  live data, starting with the weather, and the big knob walks it forward.
- The app can see the feeds and write a key that reads one.

## [0.1.0] - 2026-10-22

### Added
- Pult: per-application scene switching for the Ajazz AKP03E stream dock, a Rust
  daemon (`pultd`) paired with a SwiftUI app over a control socket.
- Bring-your-own animations with a live preview, a picture for the hours the Mac
  is asleep, and, deliberately, nothing that keeps the Mac awake.

[0.4.3]: https://github.com/devic021/pult-akp03e/releases/tag/v0.4.3
[0.4.2]: https://github.com/devic021/pult-akp03e/compare/v0.4.1...v0.4.2
[0.4.1]: https://github.com/devic021/pult-akp03e/releases/tag/v0.4.1
[0.4.0]: https://github.com/devic021/pult-akp03e/releases/tag/v0.4.0
[0.3.0]: https://github.com/devic021/pult-akp03e/releases/tag/v0.3.0
[0.2.0]: https://github.com/devic021/pult-akp03e/releases/tag/v0.2.0
[0.1.0]: https://github.com/devic021/pult-akp03e/releases/tag/v0.1.0
