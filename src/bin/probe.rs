//! Read-only probe for the Ajazz AKP03E (VID 0x0300 / PID 0x3002).
//!
//! Two modes:
//!   probe          SDK-level events (buttons, encoders)
//!   probe --raw    hex dump of raw HID input packets
//!
//! Neither mode writes images or changes brightness. Reading does send the
//! device's init packet, which the SDK does implicitly on first access.

use std::sync::Arc;
use std::time::Duration;

use ajazz_sdk::{new_hidapi, AjazzError, Event, Kind};
use pult::device::{self, VENDOR_USAGE_PAGE};
use hidapi::HidApi;

fn main() -> anyhow::Result<()> {
    let raw_mode = std::env::args().any(|a| a == "--raw");

    let hid = new_hidapi()?;

    enumerate(&hid);

    let found = device::find(&hid)?;
    println!("\nFound {:?}  serial={}", found.kind, found.serial);
    describe(found.kind);

    if raw_mode {
        return raw_dump(&hid, &found);
    }

    println!("\nConnecting to vendor pipe {}...", found.path.to_string_lossy());
    let device = device::open_path(&hid, found.kind, &found.path, 10)?;

    println!("  manufacturer : {}", device.manufacturer()?);
    println!("  product      : {}", device.product()?);
    println!("  serial       : {}", device.serial_number()?);
    println!("  firmware     : {}", device.firmware_version()?);

    // The SDK hands out readers through an Arc; this probe is single-threaded.
    #[allow(clippy::arc_with_non_send_sync)]
    let device = Arc::new(device);
    let reader = device.get_reader();

    println!("\nListening. Press keys / turn knobs. Ctrl-C to stop.\n");
    loop {
        match reader.read(Some(Duration::from_millis(1000))) {
            Ok(events) => {
                for event in events {
                    match event {
                        Event::ButtonDown(k) => println!("  button {k} down"),
                        Event::ButtonUp(k) => println!("  button {k} up"),
                        Event::EncoderDown(e) => println!("  encoder {e} down"),
                        Event::EncoderUp(e) => println!("  encoder {e} up"),
                        Event::EncoderTwist(e, t) => println!("  encoder {e} twist {t:+}"),
                    }
                }
            }
            // An unrecognised action code is worth seeing, not worth quitting over:
            // undocumented codes are exactly what this probe is here to find.
            Err(AjazzError::BadData) => continue,
            Err(e) => {
                eprintln!("read error: {e}");
                break;
            }
        }
    }

    Ok(())
}

/// Lists every HID interface the Mirabox vendor IDs expose, so we can see
/// which one is the image/event pipe and which is the plain keyboard.
fn enumerate(hid: &HidApi) {
    println!("HID interfaces on Mirabox vendor IDs (0x0300 / 0x5548):");
    for d in hid.device_list() {
        if d.vendor_id() != 0x0300 && d.vendor_id() != 0x5548 {
            continue;
        }
        let tag = if d.usage_page() == VENDOR_USAGE_PAGE {
            "  <- vendor pipe"
        } else {
            ""
        };
        println!(
            "  {:04x}:{:04x}  iface={:<3} usage_page=0x{:04x} usage=0x{:02x} serial={}{}",
            d.vendor_id(),
            d.product_id(),
            d.interface_number(),
            d.usage_page(),
            d.usage(),
            d.serial_number().unwrap_or("-"),
            tag
        );
    }
}

fn describe(kind: Kind) {
    let (rows, cols) = kind.key_layout();
    let fmt = kind.key_image_format();
    println!("\nGeometry for {kind:?}:");
    println!("  keys total   : {}", kind.key_count());
    println!("  display keys : {}", kind.display_key_count());
    println!("  layout       : {rows} x {cols}");
    println!("  encoders     : {}", kind.encoder_count());
    println!(
        "  key image    : {:?} {}x{} rot={:?} mirror={:?}",
        fmt.mode, fmt.size.0, fmt.size.1, fmt.rotation, fmt.mirror
    );
    match kind.boot_logo_size() {
        Some((w, h)) => println!("  boot logo    : {w}x{h}"),
        None => println!("  boot logo    : unsupported"),
    }
}

/// Dumps raw input packets, bypassing the SDK's parser, so undocumented action
/// codes show up as hex instead of being swallowed as bad data.
fn raw_dump(hid: &HidApi, found: &device::Found) -> anyhow::Result<()> {
    println!("\nRaw dump from {:?}", found.path);
    println!("Press keys / turn knobs. Ctrl-C to stop.\n");

    let device = hid.open_path(&found.path)?;
    let mut buf = [0u8; 512];

    loop {
        let n = device.read_timeout(&mut buf, 1000)?;
        if n == 0 || buf[0] == 0 {
            continue;
        }
        let shown = n.min(16);
        let hex: Vec<String> = buf[..shown].iter().map(|b| format!("{b:02x}")).collect();
        println!("  {n:3} bytes | {} | action=0x{:02x}", hex.join(" "), buf[9]);
    }
}
