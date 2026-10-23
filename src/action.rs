//! Running what a key is bound to.

use std::process::{Command, Stdio};

use anyhow::{Context, Result};

use crate::config::{Action, Hour, Mute, Page};

/// A key press can ask for a different scene or page; everything else is a
/// side effect.
pub enum Outcome {
    Nothing,
    /// The level moved, and the dock should show how loud it is now.
    Sound(crate::sound::Sound),
    /// The output was silenced or let go, which is a different question from
    /// how loud it is and gets a different picture.
    Muted(crate::sound::Sound),
    SwitchScene(String),
    TurnPage(Turn),
    /// Move the whole scene through the forecast.
    Scrub(Hour),
}

/// Where a page action lands, once the number of pages is known.
#[derive(Debug, Clone, Copy)]
pub struct Turn(Page);

impl Turn {
    /// Applies the turn, wrapping around the ends: the knob that pages should
    /// never reach a dead stop.
    pub fn apply(self, page: usize, pages: usize) -> usize {
        let pages = pages.max(1);
        match self.0 {
            Page::Next => (page + 1) % pages,
            Page::Prev => (page + pages - 1) % pages,
            Page::First => 0,
        }
    }
}

/// One-line description of a binding, for the log.
pub fn describe(action: &Action) -> String {
    if let Some(app) = &action.app {
        format!("open {app:?}")
    } else if let Some(command) = &action.run {
        format!("run {command:?}")
    } else if let Some(shortcut) = &action.shortcut {
        format!("shortcut {shortcut:?}")
    } else if let Some(delta) = action.volume {
        format!("volume {delta:+}")
    } else if let Some(mute) = action.mute {
        format!("mute {mute:?}").to_lowercase()
    } else if let Some(scene) = &action.scene {
        format!("scene {scene:?}")
    } else if let Some(page) = action.page {
        format!("page {page:?}").to_lowercase()
    } else if let Some(hour) = action.hour {
        format!("hour {hour:?}").to_lowercase()
    } else {
        "nothing".to_string()
    }
}

/// Checks a shortcut without sending it, so a typo fails at config load.
pub fn check_shortcut(shortcut: &str) -> Result<()> {
    applescript_for(shortcut).map(|_| ())
}

pub fn run(action: &Action) -> Result<Outcome> {
    if let Some(app) = &action.app {
        open_app(app)?;
        return Ok(Outcome::Nothing);
    }

    if let Some(command) = &action.run {
        // Detached: a key press must not block the event loop, and we do not
        // want the dock's output mixed into ours.
        Command::new("/bin/sh")
            .arg("-c")
            .arg(command)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .with_context(|| format!("running {command:?}"))?;
        return Ok(Outcome::Nothing);
    }

    if let Some(shortcut) = &action.shortcut {
        send_shortcut(shortcut)?;
        return Ok(Outcome::Nothing);
    }

    if let Some(delta) = action.volume {
        return Ok(Outcome::Sound(crate::sound::nudge(delta)?));
    }

    if let Some(mute) = action.mute {
        let which = match mute {
            Mute::Toggle => crate::sound::Which::Toggle,
            Mute::On => crate::sound::Which::On,
            Mute::Off => crate::sound::Which::Off,
        };
        return Ok(Outcome::Muted(crate::sound::silence(which)?));
    }

    if let Some(scene) = &action.scene {
        return Ok(Outcome::SwitchScene(scene.clone()));
    }

    if let Some(page) = action.page {
        return Ok(Outcome::TurnPage(Turn(page)));
    }

    if let Some(hour) = action.hour {
        return Ok(Outcome::Scrub(hour));
    }

    Ok(Outcome::Nothing)
}

/// Brings an application up, by bundle ID or by name.
///
/// `open` is used rather than launching the executable directly: it activates
/// an application that is already running instead of starting a second copy,
/// which is what pressing a key on a dock should do.
fn open_app(app: &str) -> Result<()> {
    // A bundle ID has dots and no slashes; anything else is a name or a path.
    let by_id = app.contains('.') && !app.contains('/');
    let selector = if by_id { "-b" } else { "-a" };

    Command::new("/usr/bin/open")
        .arg(selector)
        .arg(app)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .with_context(|| format!("opening {app:?}"))?;

    Ok(())
}

/// Sends a keystroke through System Events.
///
/// This is the one action that needs a permission: the process running the
/// daemon must be allowed under Privacy & Security > Accessibility, or macOS
/// silently drops the keystroke.
fn send_shortcut(shortcut: &str) -> Result<()> {
    let script = applescript_for(shortcut)?;
    osascript(&script).with_context(|| format!("sending shortcut {shortcut:?}"))
}

fn applescript_for(shortcut: &str) -> Result<String> {
    let mut modifiers = Vec::new();
    let mut key = None;

    for part in shortcut.split('+').map(str::trim).filter(|p| !p.is_empty()) {
        match part.to_lowercase().as_str() {
            "cmd" | "command" => modifiers.push("command down"),
            "ctrl" | "control" => modifiers.push("control down"),
            "alt" | "opt" | "option" => modifiers.push("option down"),
            "shift" => modifiers.push("shift down"),
            _ => key = Some(part.to_string()),
        }
    }

    let key = key.with_context(|| format!("shortcut {shortcut:?} names no key"))?;
    if key.chars().count() > 1 && key_code(&key).is_none() {
        anyhow::bail!("shortcut {shortcut:?} ends in {key:?}, which is not a key name");
    }
    let using = if modifiers.is_empty() {
        String::new()
    } else {
        format!(" using {{{}}}", modifiers.join(", "))
    };

    // Keys that produce no character have to go by key code.
    let press = match key_code(&key) {
        Some(code) => format!("key code {code}"),
        None => format!("keystroke {key:?}"),
    };

    Ok(format!(
        "tell application \"System Events\" to {press}{using}"
    ))
}

/// Virtual key codes for the keys that `keystroke` cannot express.
fn key_code(key: &str) -> Option<u16> {
    let code = match key.to_lowercase().as_str() {
        "return" | "enter" => 36,
        "tab" => 48,
        "space" => 49,
        "delete" | "backspace" => 51,
        "escape" | "esc" => 53,
        "left" => 123,
        "right" => 124,
        "down" => 125,
        "up" => 126,
        "home" => 115,
        "end" => 119,
        "pageup" => 116,
        "pagedown" => 121,
        "f1" => 122,
        "f2" => 120,
        "f3" => 99,
        "f4" => 118,
        "f5" => 96,
        "f6" => 97,
        "f7" => 98,
        "f8" => 100,
        "f9" => 101,
        "f10" => 109,
        "f11" => 103,
        "f12" => 111,
        "f13" => 105,
        "f14" => 107,
        "f15" => 113,
        _ => return None,
    };
    Some(code)
}

/// Nudges output volume, clamped by macOS itself to 0-100.
fn osascript(script: &str) -> Result<()> {
    let output = Command::new("/usr/bin/osascript")
        .arg("-e")
        .arg(script)
        .output()
        .context("running osascript")?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        // -1002 is macOS refusing synthetic keystrokes, which is a permission
        // to grant rather than anything wrong with the script.
        if stderr.contains("not allowed to send keystrokes") || stderr.contains("(1002)") {
            anyhow::bail!(
                "macOS blocked the keystroke. Allow the program running this daemon \
                 under System Settings > Privacy & Security > Accessibility."
            );
        }
        anyhow::bail!("osascript failed: {}", stderr.trim());
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn modifiers_and_characters() {
        assert_eq!(
            applescript_for("cmd+shift+4").unwrap(),
            "tell application \"System Events\" to keystroke \"4\" \
             using {command down, shift down}"
        );
    }

    #[test]
    fn special_keys_go_by_code() {
        assert_eq!(
            applescript_for("f8").unwrap(),
            "tell application \"System Events\" to key code 100"
        );
        assert_eq!(
            applescript_for("ctrl+left").unwrap(),
            "tell application \"System Events\" to key code 123 using {control down}"
        );
    }

    #[test]
    fn a_shortcut_needs_a_key() {
        assert!(applescript_for("cmd+shift").is_err());
    }

    #[test]
    fn paging_wraps_around() {
        assert_eq!(Turn(Page::Next).apply(0, 3), 1);
        assert_eq!(Turn(Page::Next).apply(2, 3), 0);
        assert_eq!(Turn(Page::Prev).apply(0, 3), 2);
        assert_eq!(Turn(Page::First).apply(2, 3), 0);
        // A scene that fits on one page cannot page anywhere.
        assert_eq!(Turn(Page::Next).apply(0, 1), 0);
    }

    #[test]
    fn a_word_that_is_not_a_key_name_is_rejected() {
        assert!(check_shortcut("cmd+plus").is_err());
        assert!(check_shortcut("cmd+=").is_ok());
        assert!(check_shortcut("cmd+shift+left").is_ok());
    }
}
