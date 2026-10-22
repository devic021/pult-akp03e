//! Finding and opening the dock on macOS.

use std::ffi::{CStr, CString};
use std::thread::sleep;
use std::time::Duration;

use ajazz_sdk::{Ajazz, Kind};
use anyhow::{anyhow, Context, Result};
use hidapi::HidApi;

/// Vendor-defined usage page used by the AKP03 image/event pipe.
pub const VENDOR_USAGE_PAGE: u16 = 0xFFA0;

/// A dock we know how to talk to.
pub struct Found {
    pub kind: Kind,
    pub serial: String,
    /// Path of the vendor pipe, not of the device as a whole.
    pub path: CString,
}

/// Locates the first Mirabox/Ajazz dock and returns its vendor pipe.
///
/// We pick the interface ourselves rather than letting the SDK look the device
/// up by serial: the dock also exposes a plain keyboard under the same
/// VID/PID/serial, and macOS refuses that interface without Input Monitoring.
pub fn find(hid: &HidApi) -> Result<Found> {
    hid.device_list()
        .filter(|d| d.usage_page() == VENDOR_USAGE_PAGE)
        .find_map(|d| {
            let kind = Kind::from_vid_pid(d.vendor_id(), d.product_id())?;
            Some(Found {
                kind,
                serial: d.serial_number().unwrap_or("-").to_string(),
                path: d.path().to_owned(),
            })
        })
        .ok_or_else(|| {
            anyhow!("no Ajazz dock found (looked for a device on usage page 0x{VENDOR_USAGE_PAGE:04X})")
        })
}

/// Opens a dock's vendor pipe, retrying while another process still holds it.
pub fn open_path(hid: &HidApi, kind: Kind, path: &CStr, attempts: u8) -> Result<Ajazz> {
    let mut last = None;
    for _ in 0..attempts.max(1) {
        match Ajazz::connect_path(hid, kind, path) {
            Ok(device) => return Ok(device),
            Err(e) => {
                last = Some(e);
                sleep(Duration::from_millis(100));
            }
        }
    }

    Err(last
        .map(anyhow::Error::from)
        .unwrap_or_else(|| anyhow!("connect failed without an error")))
        .with_context(|| format!("opening vendor pipe {}", path.to_string_lossy()))
}

/// Finds and opens the first dock.
pub fn open(hid: &HidApi) -> Result<(Found, Ajazz)> {
    let found = find(hid)?;
    let device = open_path(hid, found.kind, &found.path, 10)?;
    Ok((found, device))
}
