//! Configuration: scenes, what each key does, and which app selects which scene.

use std::collections::BTreeMap;
use std::fs;
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
    pub scenes: BTreeMap<String, Scene>,
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
    /// Whether anything on `page` moves on its own, and so needs a redraw clock.
    pub fn is_animated(&self, page: usize, per_page: usize) -> bool {
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
        usize::from(self.run.is_some())
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
        let config: Config = toml::from_str(&text)
            .with_context(|| format!("parsing config {}", path.display()))?;
        config.validate()?;
        Ok(config)
    }

    /// Rejects what would otherwise fail silently at runtime: a missing default
    /// scene, a key bound to two actions, a `scene` action pointing nowhere.
    pub fn validate(&self) -> Result<()> {
        if !self.scenes.contains_key(&self.default) {
            bail!("default scene {:?} is not defined", self.default);
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
