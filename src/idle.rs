//! How long since anyone touched this Mac.
//!
//! Asked of CoreGraphics rather than of `ioreg -c IOHIDSystem`: the shell route
//! spawns a process and takes tens of milliseconds, which is a sizeable share
//! of the loop's poll budget spent on one number. This is a framework call that
//! costs nothing and needs no permission.
//!
//! One thing it cannot see: the dock's own keys are a vendor HID device, not a
//! keyboard, so pressing one does not count as input here. The caller folds in
//! its own last-press time, or the dock would fall asleep under your hand.

use std::time::Duration;

#[link(name = "ApplicationServices", kind = "framework")]
extern "C" {
    fn CGEventSourceSecondsSinceLastEventType(state: i32, event: u32) -> f64;
    fn CGMainDisplayID() -> u32;
    fn CGDisplayIsAsleep(display: u32) -> i32;
}

/// `kCGEventSourceStateHIDSystemState`: the real hardware, not a synthesised
/// event stream.
const HID_SYSTEM_STATE: i32 = 1;
/// `kCGAnyInputEventType`.
const ANY_INPUT: u32 = 0xFFFF_FFFF;

/// Seconds since the last keyboard or pointer event.
pub fn since_input() -> Duration {
    let seconds = unsafe { CGEventSourceSecondsSinceLastEventType(HID_SYSTEM_STATE, ANY_INPUT) };
    Duration::from_secs_f64(seconds.max(0.0))
}

/// Whether the main display has gone dark.
///
/// Worth checking separately: a dock lighting up the room with the weather,
/// for an empty room, is the thing an idle screen is supposed to avoid.
pub fn display_asleep() -> bool {
    unsafe { CGDisplayIsAsleep(CGMainDisplayID()) != 0 }
}

/// Parses `30s`, `5m`, `1h`, or a bare number of seconds.
pub fn parse_duration(text: &str) -> Option<Duration> {
    let text = text.trim();
    let (number, scale) = match text.chars().last()? {
        's' => (&text[..text.len() - 1], 1),
        'm' => (&text[..text.len() - 1], 60),
        'h' => (&text[..text.len() - 1], 3600),
        _ => (text, 1),
    };

    let value: f64 = number.trim().parse().ok()?;
    if value < 0.0 {
        return None;
    }
    Some(Duration::from_secs_f64(value * scale as f64))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn durations_read_the_way_people_write_them() {
        assert_eq!(parse_duration("30s"), Some(Duration::from_secs(30)));
        assert_eq!(parse_duration("5m"), Some(Duration::from_secs(300)));
        assert_eq!(parse_duration("1h"), Some(Duration::from_secs(3600)));
        assert_eq!(parse_duration("90"), Some(Duration::from_secs(90)));
        assert_eq!(parse_duration("2.5m"), Some(Duration::from_secs(150)));
        assert_eq!(parse_duration("later"), None);
        assert_eq!(parse_duration("-5m"), None);
    }

    #[test]
    fn the_machine_answers_how_long_it_has_been_alone() {
        // Whatever it says, it must be a real number and not negative.
        let idle = since_input();
        assert!(idle.as_secs_f64() >= 0.0);
        assert!(idle.as_secs_f64() < 60.0 * 60.0 * 24.0 * 30.0);
    }
}
