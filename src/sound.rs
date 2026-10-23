//! The output volume, asked of CoreAudio directly.
//!
//! The alternative, and what this used to do, is `osascript -e 'set volume
//! output volume N'`. That spawns a process for every detent of a knob, which
//! is fifty to a hundred milliseconds each: turn the knob quickly and the
//! changes queue up behind each other. This is a property read and a property
//! write, it needs no permission, and it returns the new state so the dock can
//! show what just happened.
//!
//! What it deliberately does not do is press the volume key for you. That is
//! the only way to make macOS draw its own volume overlay, and it needs the
//! right to send keystrokes, arrives in the system's own sixteenths rather
//! than the step the configuration asks for, and costs a round trip per
//! detent. The dock draws its own instead, where your hand already is.

use std::ffi::c_void;

use anyhow::{bail, Result};

/// Four-character codes, as CoreAudio spells its selectors.
const fn code(text: &[u8; 4]) -> u32 {
    u32::from_be_bytes(*text)
}

const SYSTEM_OBJECT: u32 = 1;
const DEFAULT_OUTPUT: u32 = code(b"dOut");
const SCOPE_GLOBAL: u32 = code(b"glob");
const SCOPE_OUTPUT: u32 = code(b"outp");
const MAIN_ELEMENT: u32 = 0;
/// The one knob that means "the volume" whatever the device's channels are.
const VIRTUAL_MAIN_VOLUME: u32 = code(b"vmvc");
const VOLUME_SCALAR: u32 = code(b"volm");
const MUTE: u32 = code(b"mute");

#[repr(C)]
struct Address {
    selector: u32,
    scope: u32,
    element: u32,
}

/// Where the output stands: level from 0 to 1, and whether it is silenced.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Sound {
    pub level: f32,
    pub muted: bool,
}

/// Moves the volume by that many percentage points and says where it landed.
pub fn nudge(delta: i32) -> Result<Sound> {
    let device = default_output()?;
    let current = level(device).unwrap_or(0.0);
    let wanted = (current + delta as f32 / 100.0).clamp(0.0, 1.0);
    set_level(device, wanted)?;

    // Turning it up past silence unmutes, which is what every other volume
    // control on this machine does and what a hand reaching for a knob means.
    if delta > 0 && muted(device).unwrap_or(false) {
        let _ = set_muted(device, false);
    }

    Ok(read(device))
}

/// Silences the output, or lets it speak again.
pub fn silence(which: Which) -> Result<Sound> {
    let device = default_output()?;
    let wanted = match which {
        Which::Toggle => !muted(device).unwrap_or(false),
        Which::On => true,
        Which::Off => false,
    };
    set_muted(device, wanted)?;
    Ok(read(device))
}

/// What to do to the mute.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Which {
    Toggle,
    On,
    Off,
}

/// The state as it stands, for anything that wants to show it.
pub fn now() -> Option<Sound> {
    default_output().ok().map(read)
}

fn read(device: u32) -> Sound {
    Sound {
        level: level(device).unwrap_or(0.0),
        muted: muted(device).unwrap_or(false),
    }
}

fn default_output() -> Result<u32> {
    let address = Address {
        selector: DEFAULT_OUTPUT,
        scope: SCOPE_GLOBAL,
        element: MAIN_ELEMENT,
    };
    let mut device: u32 = 0;
    let mut size = std::mem::size_of::<u32>() as u32;

    let status = unsafe {
        AudioObjectGetPropertyData(
            SYSTEM_OBJECT,
            &address,
            0,
            std::ptr::null(),
            &mut size,
            &mut device as *mut u32 as *mut c_void,
        )
    };
    if status != 0 || device == 0 {
        bail!("no default output device ({status})");
    }
    Ok(device)
}

/// The main volume, or the loudest channel when the device has no main.
///
/// Not every device answers `vmvc`: an aggregate or a USB interface may only
/// carry per-channel scalars, and a volume knob that silently does nothing on
/// such a device is worse than one that is a little coarse.
fn level(device: u32) -> Option<f32> {
    if let Some(value) = float(device, VIRTUAL_MAIN_VOLUME, MAIN_ELEMENT) {
        return Some(value);
    }
    let left = float(device, VOLUME_SCALAR, 1);
    let right = float(device, VOLUME_SCALAR, 2);
    match (left, right) {
        (Some(left), Some(right)) => Some(left.max(right)),
        (Some(only), None) | (None, Some(only)) => Some(only),
        (None, None) => None,
    }
}

fn set_level(device: u32, value: f32) -> Result<()> {
    let value = value.clamp(0.0, 1.0);
    if set_float(device, VIRTUAL_MAIN_VOLUME, MAIN_ELEMENT, value).is_ok() {
        return Ok(());
    }

    let left = set_float(device, VOLUME_SCALAR, 1, value);
    let right = set_float(device, VOLUME_SCALAR, 2, value);
    if left.is_err() && right.is_err() {
        bail!("this output has no volume anything can set");
    }
    Ok(())
}

fn muted(device: u32) -> Option<bool> {
    let address = Address {
        selector: MUTE,
        scope: SCOPE_OUTPUT,
        element: MAIN_ELEMENT,
    };
    let mut value: u32 = 0;
    let mut size = std::mem::size_of::<u32>() as u32;
    let status = unsafe {
        AudioObjectGetPropertyData(
            device,
            &address,
            0,
            std::ptr::null(),
            &mut size,
            &mut value as *mut u32 as *mut c_void,
        )
    };
    (status == 0).then_some(value != 0)
}

fn set_muted(device: u32, value: bool) -> Result<()> {
    let address = Address {
        selector: MUTE,
        scope: SCOPE_OUTPUT,
        element: MAIN_ELEMENT,
    };
    let value: u32 = u32::from(value);
    let status = unsafe {
        AudioObjectSetPropertyData(
            device,
            &address,
            0,
            std::ptr::null(),
            std::mem::size_of::<u32>() as u32,
            &value as *const u32 as *const c_void,
        )
    };
    if status != 0 {
        bail!("this output cannot be muted ({status})");
    }
    Ok(())
}

fn float(device: u32, selector: u32, element: u32) -> Option<f32> {
    let address = Address {
        selector,
        scope: SCOPE_OUTPUT,
        element,
    };
    if !unsafe { AudioObjectHasProperty(device, &address) } {
        return None;
    }

    let mut value: f32 = 0.0;
    let mut size = std::mem::size_of::<f32>() as u32;
    let status = unsafe {
        AudioObjectGetPropertyData(
            device,
            &address,
            0,
            std::ptr::null(),
            &mut size,
            &mut value as *mut f32 as *mut c_void,
        )
    };
    (status == 0).then_some(value)
}

fn set_float(device: u32, selector: u32, element: u32, value: f32) -> Result<()> {
    let address = Address {
        selector,
        scope: SCOPE_OUTPUT,
        element,
    };
    let status = unsafe {
        AudioObjectSetPropertyData(
            device,
            &address,
            0,
            std::ptr::null(),
            std::mem::size_of::<f32>() as u32,
            &value as *const f32 as *const c_void,
        )
    };
    if status != 0 {
        bail!("property not settable ({status})");
    }
    Ok(())
}

#[link(name = "CoreAudio", kind = "framework")]
extern "C" {
    fn AudioObjectGetPropertyData(
        object: u32,
        address: *const Address,
        qualifier_size: u32,
        qualifier: *const c_void,
        data_size: *mut u32,
        data: *mut c_void,
    ) -> i32;
    fn AudioObjectSetPropertyData(
        object: u32,
        address: *const Address,
        qualifier_size: u32,
        qualifier: *const c_void,
        data_size: u32,
        data: *const c_void,
    ) -> i32;
    fn AudioObjectHasProperty(object: u32, address: *const Address) -> bool;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_machine_says_how_loud_it_is() {
        // Whatever it answers, it has to be a real level in range. A Mac with
        // no output at all is the one case where there is nothing to check.
        let Some(sound) = now() else {
            return;
        };
        assert!((0.0..=1.0).contains(&sound.level), "{sound:?}");
    }

    #[test]
    fn four_character_codes_are_what_coreaudio_expects() {
        assert_eq!(code(b"dOut"), 0x644F_7574);
        assert_eq!(code(b"mute"), 0x6D75_7465);
        assert_eq!(code(b"vmvc"), 0x766D_7663);
    }
}
