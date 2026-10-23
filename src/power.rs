//! Knowing when the Mac is going to sleep.
//!
//! The dock has no processor of its own: every frame comes from here, so when
//! the Mac sleeps the animation stops wherever it had reached. The dock then
//! holds that frame, which means the frame it holds all night is ours to
//! choose, if we are told before it happens.
//!
//! Deliberately absent: anything that keeps the Mac awake. A key pad must
//! never be the reason a laptop does not sleep, so no power assertion is taken
//! here and none can be configured.

use std::ffi::c_void;

use core_foundation::string::CFStringRef;

// ---------------------------------------------------------------------------
// Knowing when the Mac is about to sleep
//
// The dock holds whatever frame it was sent last, so the frame it is holding
// while the Mac sleeps is ours to choose, but only if we are told before it
// happens. macOS announces it through IOKit, to a callback on a run loop, and
// waits for an acknowledgement before going down. That wait is what lets the
// daemon paint one last picture.

use std::sync::mpsc::{sync_channel, Receiver, SyncSender};
use std::sync::OnceLock;
use std::time::Duration;

#[allow(non_camel_case_types)]
type io_service_t = u32;
#[allow(non_camel_case_types)]
type io_connect_t = u32;
#[allow(non_camel_case_types)]
type io_object_t = u32;

#[link(name = "IOKit", kind = "framework")]
extern "C" {
    fn IORegisterForSystemPower(
        refcon: *mut c_void,
        port: *mut *mut c_void,
        callback: extern "C" fn(*mut c_void, io_service_t, u32, *mut c_void),
        notifier: *mut io_object_t,
    ) -> io_connect_t;
    fn IONotificationPortGetRunLoopSource(port: *mut c_void) -> *mut c_void;
    fn IOAllowPowerChange(root: io_connect_t, notification: isize) -> i32;
}

#[link(name = "CoreFoundation", kind = "framework")]
extern "C" {
    fn CFRunLoopGetCurrent() -> *mut c_void;
    fn CFRunLoopAddSource(loop_: *mut c_void, source: *mut c_void, mode: CFStringRef);
    fn CFRunLoopRun();
    static kCFRunLoopCommonModes: CFStringRef;
}

/// `kIOMessageSystemWillSleep`.
const WILL_SLEEP: u32 = 0xE000_0280;
/// `kIOMessageSystemHasPoweredOn`.
const HAS_POWERED_ON: u32 = 0xE000_0300;

/// What the watcher reports.
pub enum Sleeping {
    /// The Mac is going down. Paint, then drop the guard to let it.
    Soon(Permission),
    /// It is back.
    Woke,
}

/// Holds the Mac at the threshold of sleep until it is dropped.
///
/// macOS allows around thirty seconds here; a repaint takes five milliseconds,
/// so there is no need to hurry, but the guard must not be kept.
pub struct Permission {
    root: io_connect_t,
    notification: isize,
}

impl Drop for Permission {
    fn drop(&mut self) {
        unsafe {
            IOAllowPowerChange(self.root, self.notification);
        }
    }
}

static EVENTS: OnceLock<SyncSender<Sleeping>> = OnceLock::new();
static ROOT: OnceLock<io_connect_t> = OnceLock::new();

extern "C" fn on_power_change(
    _refcon: *mut c_void,
    _service: io_service_t,
    message: u32,
    argument: *mut c_void,
) {
    let Some(events) = EVENTS.get() else { return };

    match message {
        WILL_SLEEP => {
            let permission = Permission {
                root: *ROOT.get().unwrap_or(&0),
                notification: argument as isize,
            };
            // If nobody is listening the guard drops here and sleep proceeds,
            // which is the right failure: never hold a Mac awake by accident.
            let _ = events.send(Sleeping::Soon(permission));
        }
        HAS_POWERED_ON => {
            let _ = events.send(Sleeping::Woke);
        }
        _ => {}
    }
}

/// Starts watching for sleep and wake. Call once.
///
/// The thread it spawns runs a CoreFoundation run loop, which is what IOKit
/// delivers these notifications on; it never returns.
pub fn watch_sleep() -> Option<Receiver<Sleeping>> {
    // Depth of one: a second notification before the first is handled means
    // something is very wrong, and dropping it lets sleep proceed.
    let (tx, rx) = sync_channel(1);
    EVENTS.set(tx).ok()?;

    std::thread::Builder::new()
        .name("pult-power".into())
        .spawn(|| unsafe {
            let mut port: *mut c_void = std::ptr::null_mut();
            let mut notifier: io_object_t = 0;
            let root = IORegisterForSystemPower(
                std::ptr::null_mut(),
                &mut port,
                on_power_change,
                &mut notifier,
            );
            if root == 0 || port.is_null() {
                return;
            }
            let _ = ROOT.set(root);

            CFRunLoopAddSource(
                CFRunLoopGetCurrent(),
                IONotificationPortGetRunLoopSource(port),
                kCFRunLoopCommonModes,
            );
            CFRunLoopRun();
        })
        .ok()?;

    Some(rx)
}

/// How long the loop will wait for its own painting before letting sleep go on.
pub const PAINT_BEFORE_SLEEP: Duration = Duration::from_secs(2);

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_sleep_watcher_starts() {
        // It can only be started once per process, so this also proves the
        // second call is refused rather than panicking.
        let first = watch_sleep();
        assert!(first.is_some());
        assert!(watch_sleep().is_none());
    }

}
