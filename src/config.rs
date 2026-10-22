//! Configuration: scenes, what each key does, and which app selects which scene.

use std::collections::BTreeMap;
use std::fs;
use std::time::Duration;
use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};

/// Starter config written on first run, so the daemon has something to show.
pub const EXAMPLE: &str = include_str!("../config.example.toml");

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    /// Backlight, 0-100.
    #[serde(default = "default_brightness")]
    pub brightness: u8,
    /// How often to ask macOS which app is in front.
    #[serde(default = "default_poll_ms")]
    pub poll_ms: u64,
    /// TrueType font for key labels; a system font is used when unset.
    #[serde(default)]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub font: Option<PathBuf>,
    /// Light a key up briefly when it is pressed.
    #[serde(default = "default_press_feedback")]
    pub press_feedback: bool,
    /// Scene to fall back to when no scene claims the frontmost app.
    pub default: String,
    /// What the dock does when nobody has touched the Mac for a while.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub idle: Option<Idle>,
    pub scenes: BTreeMap<String, Scene>,
}

/// The idle screen.
///
/// One block, never a flag per scene: two scenes both claiming the idle slot is
/// an ambiguity that only ever becomes a bug report.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Idle {
    /// How long since the last keyboard or pointer event: `30s`, `3m`, `1h`.
    pub after: String,
    /// The scene to show. Usually a canvas, but any scene will do.
    pub scene: String,
    /// Dimmer than working brightness, and never below a quarter: the backlight
    /// shifts colour at the bottom of its range.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub brightness: Option<u8>,
    /// Follow the Mac's display to sleep.
    ///
    /// Off by default: the point of an idle screen is that it keeps running
    /// when you look away. Turn it on if the dock lighting a dark room at
    /// night bothers you.
    ///
    /// This is about the *display* sleeping while the Mac stays awake. Nothing
    /// can be done about full system sleep: the daemon is suspended with
    /// everything else, so the dock holds its last frame until the Mac wakes.
    #[serde(default)]
    pub dark_when_display_sleeps: bool,
    /// Waking the dock with a key should not also fire what that key does.
    #[serde(default = "yes")]
    pub swallow_first_press: bool,
    /// The picture to leave on the dock while the Mac sleeps.
    ///
    /// Nothing here can animate: the daemon is frozen along with the rest of
    /// the Mac, so whatever was sent last is what stays on the keys until it
    /// wakes. This is that last frame — a PNG or JPEG, drawn across the whole
    /// dock. Absent means the dock simply keeps whatever it was showing.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sleep_image: Option<PathBuf>,
}

fn yes() -> bool {
    true
}

fn is_default_fit(fit: &crate::animation::Fit) -> bool {
    *fit == crate::animation::Fit::default()
}

fn is_zero(value: &u16) -> bool {
    *value == 0
}

impl Idle {
    pub fn after(&self) -> Duration {
        crate::idle::parse_duration(&self.after).unwrap_or(Duration::from_secs(180))
    }

    /// Brightness while idle, floored so the colours stay honest.
    pub fn brightness(&self) -> u8 {
        self.brightness.unwrap_or(35).clamp(25, 100)
    }
}

/// What a scene paints with.
///
/// Absent means `keys`, so every configuration written before this existed
/// keeps its meaning exactly.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Surface {
    #[serde(default)]
    pub kind: SurfaceKind,
    /// Which motion a canvas runs. Ignored when `source` names a file.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub effect: Option<crate::canvas::Effect>,
    /// An animation of your own, instead of a built-in effect.
    ///
    /// A GIF, an animated PNG, an animated WebP, a folder of numbered PNG or
    /// JPEG frames, or one still picture. Decoded once when the scene is shown;
    /// video formats are not accepted, and SVG animation is SMIL, which the
    /// renderer does not implement.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source: Option<PathBuf>,
    /// How a source that is not the canvas's shape is made to fit it.
    ///
    /// The dock is always landscape — 212x136, about 1.56:1 — so a portrait
    /// animation has to lose its edges or gain bars at the sides. `cover`
    /// crops, `contain` keeps all of it, `stretch` distorts.
    #[serde(default, skip_serializing_if = "is_default_fit")]
    pub fit: crate::animation::Fit,
    /// Quarter turns applied before fitting, for a clip filmed sideways.
    #[serde(default, skip_serializing_if = "is_zero")]
    pub rotate: u16,
    /// Override the geometry the effect would choose for itself.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mapping: Option<crate::canvas::Mapping>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fps: Option<u8>,
    /// The colour the motion is drawn in.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub color: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub background: Option<String>,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SurfaceKind {
    /// Six keys, each its own picture. What every scene was until now.
    #[default]
    Keys,
    /// One drawing spanning the whole dock, cut into six.
    Canvas,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
pub struct Scene {
    /// Bundle IDs this scene claims. A trailing `*` matches a prefix.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub apps: Vec<String>,
    /// The six keys with displays, in reading order.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub keys: Vec<Key>,
    /// The three keys without displays.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub buttons: Vec<Action>,
    /// The three encoders, left to right.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub encoders: Vec<Encoder>,
    /// What this scene paints with; absent means six separate keys.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub surface: Option<Surface>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
pub struct Key {
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub label: String,
    /// Background, `#RRGGBB`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub color: Option<String>,
    /// Label colour; picked from the background when unset.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text_color: Option<String>,
    /// A bundled icon's name, or a path to an SVG or bitmap.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub icon: Option<String>,
    /// Icon colour; follows the label when unset.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub icon_color: Option<String>,
    /// Movement to give the key while its scene is showing.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub animate: Option<Animation>,
    #[serde(flatten)]
    pub action: Action,
}

impl Scene {
    /// The canvas this scene paints with, if it paints with one.
    pub fn canvas(&self) -> Option<&Surface> {
        self.surface
            .as_ref()
            .filter(|surface| surface.kind == SurfaceKind::Canvas)
    }

    /// Whether anything on `page` moves on its own, and so needs a redraw clock.
    pub fn is_animated(&self, page: usize, per_page: usize) -> bool {
        if self.canvas().is_some() {
            return true;
        }
        self.page(page, per_page)
            .iter()
            .any(|key| key.animate.is_some())
    }

    /// How many pages this scene fills, never fewer than one.
    pub fn pages(&self, per_page: usize) -> usize {
        self.keys.len().div_ceil(per_page.max(1)).max(1)
    }

    /// The keys shown on one page, which may be shorter than a full page.
    pub fn page(&self, page: usize, per_page: usize) -> &[Key] {
        let per_page = per_page.max(1);
        let start = (page * per_page).min(self.keys.len());
        let end = (start + per_page).min(self.keys.len());
        &self.keys[start..end]
    }
}

/// What an animated key does while its scene is on screen.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Animation {
    /// The icon breathes: use it to draw the eye without shouting.
    Pulse,
    /// The icon turns: for anything that means "working".
    Spin,
    /// The background flashes: for anything that means "live" or "careful".
    Blink,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
pub struct Encoder {
    #[serde(default, skip_serializing_if = "Action::is_empty")]
    pub cw: Action,
    #[serde(default, skip_serializing_if = "Action::is_empty")]
    pub ccw: Action,
    #[serde(default, skip_serializing_if = "Action::is_empty")]
    pub press: Action,
}

/// What a key does. At most one field may be set.
#[derive(Debug, Default, Clone, Serialize, Deserialize)]
pub struct Action {
    /// Application to bring up, by bundle ID or by name.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub app: Option<String>,
    /// Shell command, run detached.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub run: Option<String>,
    /// Keystroke to send, e.g. `cmd+shift+4` or `f8`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub shortcut: Option<String>,
    /// Scene to switch to by hand.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub scene: Option<String>,
    /// Output volume change in percentage points, e.g. `-5`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub volume: Option<i32>,
    /// Move through a scene's pages: `next`, `prev` or `first`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub page: Option<Page>,
}

/// Which page of a scene to show.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Page {
    Next,
    Prev,
    First,
}

impl Action {
    pub fn is_empty(&self) -> bool {
        self.count() == 0
    }

    fn count(&self) -> usize {
        usize::from(self.app.is_some())
            + usize::from(self.run.is_some())
            + usize::from(self.shortcut.is_some())
            + usize::from(self.scene.is_some())
            + usize::from(self.volume.is_some())
            + usize::from(self.page.is_some())
    }
}

fn default_brightness() -> u8 {
    70
}

fn default_poll_ms() -> u64 {
    300
}

fn default_press_feedback() -> bool {
    true
}

impl Config {
    pub fn load(path: &Path) -> Result<Config> {
        let text = fs::read_to_string(path)
            .with_context(|| format!("reading config {}", path.display()))?;
        let mut config: Config = toml::from_str(&text)
            .with_context(|| format!("parsing config {}", path.display()))?;
        config.expand_paths();
        config.validate()?;
        Ok(config)
    }

    /// Rewrites every path in the file so a leading `~` means what it looks
    /// like it means.
    fn expand_paths(&mut self) {
        if let Some(font) = self.font.take() {
            self.font = Some(expand(&font));
        }
        if let Some(idle) = self.idle.as_mut() {
            if let Some(image) = idle.sleep_image.take() {
                idle.sleep_image = Some(expand(&image));
            }
        }
        for scene in self.scenes.values_mut() {
            if let Some(surface) = scene.surface.as_mut() {
                if let Some(source) = surface.source.take() {
                    surface.source = Some(expand(&source));
                }
            }
            for key in scene.keys.iter_mut() {
                // A bundled icon is a name, not a path; only a path can have a
                // tilde in front of it.
                if let Some(icon) = key.icon.as_ref().filter(|i| i.starts_with("~/")) {
                    key.icon = Some(expand(Path::new(icon)).to_string_lossy().into_owned());
                }
            }
        }
    }

    /// Rejects what would otherwise fail silently at runtime: a missing default
    /// scene, a key bound to two actions, a `scene` action pointing nowhere.
    pub fn validate(&self) -> Result<()> {
        if !self.scenes.contains_key(&self.default) {
            bail!("default scene {:?} is not defined", self.default);
        }

        if let Some(idle) = &self.idle {
            if !self.scenes.contains_key(&idle.scene) {
                bail!("idle scene {:?} is not defined", idle.scene);
            }
            if crate::idle::parse_duration(&idle.after).is_none() {
                bail!("idle after {:?} is not a duration like 30s, 3m or 1h", idle.after);
            }
            // A missing sleep picture is not worth refusing the whole file
            // over: the dock would stop working over a renamed image. It is
            // reported when it is reached, and the dock keeps its last frame.
        }

        for (name, scene) in &self.scenes {
            if scene.buttons.len() > 3 {
                bail!(
                    "scene {name:?} has {} buttons, the dock has 3",
                    scene.buttons.len()
                );
            }
            if scene.encoders.len() > 3 {
                bail!(
                    "scene {name:?} has {} encoders, the dock has 3",
                    scene.encoders.len()
                );
            }

            if let Some(surface) = scene.canvas() {
                if surface.effect.is_none() && surface.source.is_none() {
                    bail!("scene {name:?} is a canvas but names neither effect nor source");
                }
                for colour in [&surface.color, &surface.background].into_iter().flatten() {
                    crate::render::parse_color(colour)
                        .with_context(|| format!("in scene {name:?}"))?;
                }
            }

            for key in &scene.keys {
                if let Some(icon) = &key.icon {
                    if crate::icons::get(icon).is_none() && !Path::new(icon).exists() {
                        bail!(
                            "scene {name:?} uses icon {icon:?}, which is neither bundled \
                             nor a file. Bundled icons: {}",
                            crate::icons::names().join(", ")
                        );
                    }
                }
            }

            let keys = scene.keys.iter().map(|k| &k.action);
            let encoders = scene
                .encoders
                .iter()
                .flat_map(|e| [&e.cw, &e.ccw, &e.press]);
            for action in keys.chain(scene.buttons.iter()).chain(encoders) {
                if action.count() > 1 {
                    bail!("scene {name:?} has a key with more than one action");
                }
                if let Some(shortcut) = &action.shortcut {
                    crate::action::check_shortcut(shortcut)
                        .with_context(|| format!("in scene {name:?}"))?;
                }
                if let Some(target) = &action.scene {
                    if !self.scenes.contains_key(target) {
                        bail!("scene {name:?} switches to {target:?}, which is not defined");
                    }
                }
            }
        }

        Ok(())
    }

    /// Scene claiming `bundle_id`, or the default scene.
    pub fn scene_for(&self, bundle_id: Option<&str>) -> &str {
        let Some(id) = bundle_id else {
            return &self.default;
        };

        for (name, scene) in &self.scenes {
            if scene.apps.iter().any(|pattern| matches_app(pattern, id)) {
                return name;
            }
        }

        &self.default
    }

    pub fn scene(&self, name: &str) -> Option<&Scene> {
        self.scenes.get(name)
    }

    /// Whether any binding sends a keystroke, which is the one thing that
    /// needs a permission.
    pub fn uses_shortcuts(&self) -> bool {
        self.scenes.values().any(|scene| {
            let keys = scene.keys.iter().map(|k| &k.action);
            let encoders = scene
                .encoders
                .iter()
                .flat_map(|e| [&e.cw, &e.ccw, &e.press]);

            keys.chain(scene.buttons.iter())
                .chain(encoders)
                .any(|a| a.shortcut.is_some())
        })
    }
}

/// Expands a leading `~` to the home directory.
///
/// People write paths with a tilde and nothing in Rust expands it, so a
/// perfectly good `~/Pictures/night.png` would be reported as missing.
pub fn expand(path: &Path) -> PathBuf {
    let text = path.to_string_lossy();
    let Some(rest) = text.strip_prefix("~/") else {
        return path.to_path_buf();
    };
    match std::env::var_os("HOME") {
        Some(home) => PathBuf::from(home).join(rest),
        None => path.to_path_buf(),
    }
}

/// Matches a bundle ID against a pattern, where a trailing `*` is a prefix.
fn matches_app(pattern: &str, bundle_id: &str) -> bool {
    match pattern.strip_suffix('*') {
        Some(prefix) => bundle_id.to_lowercase().starts_with(&prefix.to_lowercase()),
        None => bundle_id.eq_ignore_ascii_case(pattern),
    }
}

/// Where the config lives: the argument, else `$XDG_CONFIG_HOME` or
/// `~/.config`. Created from [`EXAMPLE`] when it does not exist yet.
pub fn resolve_path(arg: Option<&str>) -> Result<PathBuf> {
    if let Some(arg) = arg {
        return Ok(PathBuf::from(arg));
    }

    let base = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".config")))
        .context("neither XDG_CONFIG_HOME nor HOME is set")?;

    Ok(base.join("pult").join("config.toml"))
}

/// Header written above a generated config, since serialising drops comments.
const GENERATED_HEADER: &str = "\
# Pult configuration.
#
# Written by Pult. Hand-written comments are not preserved when the app saves
# this file; keep notes in a copy if you need them.
#
# See config.example.toml in the repository for what every field means.

";

impl Config {
    /// Writes the configuration back out as TOML.
    ///
    /// The previous file is kept alongside as `.bak`: this is the one place
    /// where the app can destroy work a person typed by hand.
    pub fn save(&self, path: &Path) -> Result<()> {
        self.validate()?;

        let body = toml::to_string_pretty(self).context("serialising config")?;
        let text = format!("{GENERATED_HEADER}{body}");

        if path.exists() {
            let backup = path.with_extension("toml.bak");
            fs::copy(path, &backup)
                .with_context(|| format!("backing up {} to {}", path.display(), backup.display()))?;
        }
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }

        fs::write(path, text).with_context(|| format!("writing {}", path.display()))?;
        Ok(())
    }
}

pub fn create_if_missing(path: &Path) -> Result<bool> {
    if path.exists() {
        return Ok(false);
    }

    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("creating {}", parent.display()))?;
    }
    fs::write(path, EXAMPLE).with_context(|| format!("writing {}", path.display()))?;
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn config_survives_a_round_trip() {
        // The app edits configs as JSON and the daemon writes them back as
        // TOML; anything lost in that loop is a setting silently thrown away.
        let original: Config = toml::from_str(EXAMPLE).expect("example parses");
        let toml_text = toml::to_string_pretty(&original).expect("serialises");
        let reparsed: Config = toml::from_str(&toml_text).expect("reparses");

        assert_eq!(original.scenes.len(), reparsed.scenes.len());
        for (name, scene) in &original.scenes {
            let other = reparsed.scenes.get(name).expect("scene survives");
            assert_eq!(scene.keys.len(), other.keys.len(), "keys of {name}");
            assert_eq!(scene.apps, other.apps, "apps of {name}");
            assert_eq!(scene.encoders.len(), other.encoders.len(), "encoders of {name}");
            for (a, b) in scene.keys.iter().zip(&other.keys) {
                assert_eq!(a.label, b.label);
                assert_eq!(a.icon, b.icon);
                assert_eq!(a.action.shortcut, b.action.shortcut);
                assert_eq!(a.animate, b.animate);
            }
        }
        reparsed.validate().expect("still valid");
    }

    #[test]
    fn app_patterns() {
        assert!(matches_app("com.apple.Safari", "com.apple.Safari"));
        assert!(matches_app("com.apple.safari", "com.apple.Safari"));
        assert!(matches_app("com.adobe.*", "com.adobe.Photoshop"));
        assert!(!matches_app("com.adobe.*", "com.apple.Safari"));
    }

    #[test]
    fn example_config_is_valid() {
        let config: Config = toml::from_str(EXAMPLE).expect("example parses");
        config.validate().expect("example validates");
        assert_eq!(config.scene_for(Some("com.google.Chrome")), "chrome");
        assert_eq!(config.scene_for(Some("com.unknown.App")), config.default);
    }
}
