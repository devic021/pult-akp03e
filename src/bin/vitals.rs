//! What this Mac is doing to itself, as one line of JSON.
//!
//!   vitals [--temperature-unit celsius|fahrenheit]
//!
//! A process of its own, run by a `kind = "shell"` feed, and that is the
//! point. Reading the thermal sensors needs calls that are not public API, and
//! the one rule this project keeps about those is that they never run in the
//! process holding the dock: if a future macOS changes them underneath us, the
//! cost is one failed poll and a blank key, not a dock that stops answering.
//!
//! Nothing here needs permission, and nothing here needs root. That was worth
//! measuring rather than assuming: `powermetrics` does need it, and the advice
//! everywhere is to install a privileged helper, but on this hardware the
//! sensors arrive as HID events that any process can read.

use std::ffi::{c_void, CString};
use std::time::{SystemTime, UNIX_EPOCH};

use core_foundation::array::{CFArray, CFArrayRef};
use core_foundation::base::{CFType, CFTypeRef, TCFType};
use core_foundation::dictionary::{CFDictionary, CFDictionaryRef};
use core_foundation::number::CFNumber;
use core_foundation::string::CFString;
use serde_json::{json, Value};

/// Degrees as the caller asked for them.
///
/// Converted here rather than by a formatter on the key, so that a ramp set in
/// degrees colours by the same numbers the key shows. A ramp built for 30-85
/// Celsius would otherwise read every Fahrenheit value as scalding.
fn degrees(celsius: f64, fahrenheit: bool) -> f64 {
    if fahrenheit {
        celsius * 9.0 / 5.0 + 32.0
    } else {
        celsius
    }
}

fn main() {
    let fahrenheit = std::env::args()
        .skip_while(|argument| argument != "--temperature-unit")
        .nth(1)
        .is_some_and(|unit| unit.eq_ignore_ascii_case("fahrenheit"));

    // Every reading is optional. A Mac with no battery is a Mac Mini, not a
    // failure, and one sensor the kernel will not talk about must not take the
    // other five with it.
    let report = json!({
        "cpu": cpu(),
        "memory": memory(),
        "battery": battery(),
        "temperature": temperature(fahrenheit),
        "disk": disk(),
        "uptime": uptime(),
    });

    println!("{report}");
}

// MARK: - The processor

/// Busy share across every core, plus the load averages.
///
/// Busy is measured rather than inferred from the load average: load is a
/// queue length, and reporting it as a percentage would read as 26% on a
/// machine that is actually idle with one thread waiting on a disk.
fn cpu() -> Value {
    let cores = sysctl_int("hw.ncpu").unwrap_or(1).max(1);
    let busy = busy_share();

    let mut out = json!({ "cores": cores });
    if let Some(busy) = busy {
        out["busy"] = json!((busy * 100.0 * 10.0).round() / 10.0);
    }
    if let Some([one, five, fifteen]) = load_average() {
        out["load"] = json!((one * 100.0).round() / 100.0);
        out["load5"] = json!((five * 100.0).round() / 100.0);
        out["load15"] = json!((fifteen * 100.0).round() / 100.0);
        out["per_core"] = json!((one / cores as f64 * 1000.0).round() / 10.0);
    }
    out
}

/// Two samples a fifth of a second apart.
///
/// A single sample is the machine's whole uptime averaged together, which
/// never moves. The wait is why this is worth doing in a process that is
/// already being spawned on a timer rather than inside the dock's own loop.
fn busy_share() -> Option<f64> {
    let first = ticks()?;
    std::thread::sleep(std::time::Duration::from_millis(180));
    let second = ticks()?;

    let used = (second.0 - first.0) as f64;
    let total = (second.1 - first.1) as f64;
    (total > 0.0).then(|| (used / total).clamp(0.0, 1.0))
}

/// (busy ticks, total ticks) summed over every core.
fn ticks() -> Option<(u64, u64)> {
    const PROCESSOR_CPU_LOAD_INFO: i32 = 2;
    const CPU_STATE_MAX: usize = 4;
    const CPU_STATE_IDLE: usize = 2;

    let mut cores: u32 = 0;
    let mut info: *mut u32 = std::ptr::null_mut();
    let mut count: u32 = 0;

    let ok = unsafe {
        host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &mut cores,
            &mut info,
            &mut count,
        )
    };
    if ok != 0 || info.is_null() {
        return None;
    }

    let values = unsafe { std::slice::from_raw_parts(info, count as usize) };
    let mut busy = 0u64;
    let mut total = 0u64;
    for core in 0..cores as usize {
        for state in 0..CPU_STATE_MAX {
            let Some(tick) = values.get(core * CPU_STATE_MAX + state) else {
                continue;
            };
            total += u64::from(*tick);
            if state != CPU_STATE_IDLE {
                busy += u64::from(*tick);
            }
        }
    }

    unsafe {
        vm_deallocate(
            mach_task_self(),
            info as usize,
            count as usize * std::mem::size_of::<u32>(),
        );
    }
    Some((busy, total))
}

// MARK: - Memory

/// What is actually spoken for, the way Activity Monitor counts it.
///
/// Free memory is not the useful number on macOS: the kernel fills it with
/// cache on purpose, so a healthy Mac reports almost none and looks alarming.
/// Wired, active and compressed is the part that cannot simply be given back.
fn memory() -> Value {
    const HOST_VM_INFO64: i32 = 4;
    const COUNT: u32 = 38;

    let total = sysctl_u64("hw.memsize").unwrap_or(0);
    let page = sysctl_int("hw.pagesize").unwrap_or(16384) as u64;

    let mut stats = [0u32; COUNT as usize];
    let mut count = COUNT;
    let ok = unsafe {
        host_statistics64(
            mach_host_self(),
            HOST_VM_INFO64,
            stats.as_mut_ptr(),
            &mut count,
        )
    };
    if ok != 0 || total == 0 {
        return Value::Null;
    }

    // vm_statistics64: free, active, inactive, wire, zero_fill, ... with the
    // compressor count further down. Only the four that matter are read, by
    // index, because the struct is not stable enough to mirror in full.
    let active = u64::from(stats[1]) * page;
    let wired = u64::from(stats[3]) * page;
    let compressed = u64::from(stats[25]) * page;
    let used = active + wired + compressed;

    json!({
        "total_gb": gigabytes(total),
        "used_gb": gigabytes(used),
        "free_gb": gigabytes(total.saturating_sub(used)),
        "used_percent": ((used as f64 / total as f64) * 1000.0).round() / 10.0,
    })
}

// MARK: - Battery

/// Charge, and whether it is going up.
///
/// Through IOKit's power-source API, which is public and needs nothing: the
/// alternative is parsing `pmset`, which means another process per poll for a
/// number this returns directly.
fn battery() -> Value {
    unsafe {
        let blob = IOPSCopyPowerSourcesInfo();
        if blob.is_null() {
            return Value::Null;
        }
        let list = IOPSCopyPowerSourcesList(blob);
        if list.is_null() {
            return Value::Null;
        }

        let sources: CFArray<CFType> = CFArray::wrap_under_create_rule(list);
        let mut out = Value::Null;

        for source in sources.iter() {
            let description = IOPSGetPowerSourceDescription(blob, source.as_CFTypeRef());
            if description.is_null() {
                continue;
            }
            let description: CFDictionary<CFString, CFType> =
                CFDictionary::wrap_under_get_rule(description);

            let now = number(&description, "Current Capacity");
            let max = number(&description, "Max Capacity");
            let Some((now, max)) = now.zip(max).filter(|(_, max)| *max > 0.0) else {
                continue;
            };

            let state = text(&description, "Power Source State").unwrap_or_default();
            let charging = boolean(&description, "Is Charging").unwrap_or(false);

            let mut battery = json!({
                "percent": ((now / max) * 100.0).round(),
                "charging": charging,
                "plugged": state == "AC Power",
            });
            if let Some(cycles) = number(&description, "Cycle Count") {
                battery["cycles"] = json!(cycles.round());
            }
            // Negative means the estimate is not ready yet, which is most of
            // the first minute after plugging in or out.
            let remaining = if charging { "Time to Full" } else { "Time to Empty" };
            if let Some(minutes) = number(&description, remaining).filter(|m| *m > 0.0) {
                battery["minutes"] = json!(minutes.round());
            }

            out = battery;
            break;
        }

        out
    }
}

// MARK: - Heat

/// The hottest die, and the battery.
///
/// `tdie*` are the SoC's own dies; `tcal` is a calibration reference that sits
/// several degrees above all of them and is not a hotspot, so counting it
/// would report a Mac as hotter than it is, permanently.
fn temperature(fahrenheit: bool) -> Value {
    let mut dies: Vec<f64> = Vec::new();
    let mut battery: Option<f64> = None;

    for (name, celsius) in sensors() {
        if !(celsius.is_finite() && (-40.0..=150.0).contains(&celsius)) {
            continue;
        }
        if name.contains("tdie") {
            dies.push(celsius);
        } else if name.contains("battery") {
            battery = Some(battery.map_or(celsius, |seen: f64| seen.max(celsius)));
        }
    }

    let round = |celsius: f64| (degrees(celsius, fahrenheit) * 10.0).round() / 10.0;

    let mut out = json!({ "unit": if fahrenheit { "fahrenheit" } else { "celsius" } });
    if let Some(hottest) = dies.iter().copied().fold(None, |a: Option<f64>, b| {
        Some(a.map_or(b, |a| a.max(b)))
    }) {
        out["soc"] = json!(round(hottest));
        out["soc_mean"] = json!(round(dies.iter().sum::<f64>() / dies.len() as f64));
        out["sensors"] = json!(dies.len());
    }
    if let Some(battery) = battery {
        out["battery"] = json!(round(battery));
    }
    out
}

/// Every thermal sensor the kernel will name, as (name, celsius).
fn sensors() -> Vec<(String, f64)> {
    const EVENT_TEMPERATURE: i64 = 15;
    const FIELD_TEMPERATURE: i32 = (EVENT_TEMPERATURE as i32) << 16;
    // Usage page 0xff00, usage 5: the thermal sensors.
    const PAGE: i32 = 0xff00;
    const USAGE: i32 = 5;

    let mut found = Vec::new();
    unsafe {
        let client = IOHIDEventSystemClientCreate(std::ptr::null());
        if client.is_null() {
            return found;
        }

        let matching = CFDictionary::from_CFType_pairs(&[
            (
                CFString::new("PrimaryUsagePage").as_CFType(),
                CFNumber::from(PAGE).as_CFType(),
            ),
            (
                CFString::new("PrimaryUsage").as_CFType(),
                CFNumber::from(USAGE).as_CFType(),
            ),
        ]);
        IOHIDEventSystemClientSetMatching(client, matching.as_concrete_TypeRef());

        let services = IOHIDEventSystemClientCopyServices(client);
        if services.is_null() {
            return found;
        }
        let services: CFArray<CFType> = CFArray::wrap_under_create_rule(services);

        for service in services.iter() {
            let service = service.as_CFTypeRef();
            let name = IOHIDServiceClientCopyProperty(service, CFString::new("Product").as_concrete_TypeRef());
            let event = IOHIDServiceClientCopyEvent(service, EVENT_TEMPERATURE, 0, 0);
            if name.is_null() || event.is_null() {
                continue;
            }

            let name: CFString = CFString::wrap_under_create_rule(name as _);
            found.push((name.to_string(), IOHIDEventGetFloatValue(event, FIELD_TEMPERATURE)));
        }
    }

    found
}

// MARK: - The disk, and how long it has been up

fn disk() -> Value {
    let Ok(path) = CString::new("/") else {
        return Value::Null;
    };
    let mut stats: libc::statfs = unsafe { std::mem::zeroed() };
    if unsafe { libc::statfs(path.as_ptr(), &mut stats) } != 0 {
        return Value::Null;
    }

    let block = stats.f_bsize as u64;
    let total = stats.f_blocks * block;
    // Available, not free: the difference is the reserve only root may use,
    // and reporting that as yours is how a disk reads 2 GB free and refuses
    // to write.
    let free = stats.f_bavail * block;
    if total == 0 {
        return Value::Null;
    }

    json!({
        "total_gb": gigabytes(total),
        "free_gb": gigabytes(free),
        "used_percent": (((total - free) as f64 / total as f64) * 1000.0).round() / 10.0,
    })
}

fn uptime() -> Value {
    let Some(boot) = sysctl_boottime() else {
        return Value::Null;
    };
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|since| since.as_secs() as i64)
        .unwrap_or(0);

    json!({ "seconds": (now - boot).max(0) })
}

// MARK: - Asking the kernel

fn gigabytes(bytes: u64) -> f64 {
    ((bytes as f64 / 1_073_741_824.0) * 10.0).round() / 10.0
}

fn sysctl_int(name: &str) -> Option<i32> {
    let mut value: i32 = 0;
    let mut size = std::mem::size_of::<i32>();
    let name = CString::new(name).ok()?;
    let ok = unsafe {
        libc::sysctlbyname(
            name.as_ptr(),
            &mut value as *mut i32 as *mut c_void,
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    (ok == 0).then_some(value)
}

fn sysctl_u64(name: &str) -> Option<u64> {
    let mut value: u64 = 0;
    let mut size = std::mem::size_of::<u64>();
    let name = CString::new(name).ok()?;
    let ok = unsafe {
        libc::sysctlbyname(
            name.as_ptr(),
            &mut value as *mut u64 as *mut c_void,
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    (ok == 0).then_some(value)
}

fn load_average() -> Option<[f64; 3]> {
    #[repr(C)]
    struct LoadAvg {
        ldavg: [u32; 3],
        fscale: u64,
    }

    let mut value: LoadAvg = unsafe { std::mem::zeroed() };
    let mut size = std::mem::size_of::<LoadAvg>();
    let name = CString::new("vm.loadavg").ok()?;
    let ok = unsafe {
        libc::sysctlbyname(
            name.as_ptr(),
            &mut value as *mut LoadAvg as *mut c_void,
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    if ok != 0 || value.fscale == 0 {
        return None;
    }

    let scale = value.fscale as f64;
    Some([
        f64::from(value.ldavg[0]) / scale,
        f64::from(value.ldavg[1]) / scale,
        f64::from(value.ldavg[2]) / scale,
    ])
}

fn sysctl_boottime() -> Option<i64> {
    let mut value: libc::timeval = unsafe { std::mem::zeroed() };
    let mut size = std::mem::size_of::<libc::timeval>();
    let name = CString::new("kern.boottime").ok()?;
    let ok = unsafe {
        libc::sysctlbyname(
            name.as_ptr(),
            &mut value as *mut libc::timeval as *mut c_void,
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    (ok == 0).then_some(value.tv_sec)
}

fn number(dictionary: &CFDictionary<CFString, CFType>, key: &str) -> Option<f64> {
    dictionary
        .find(CFString::new(key))
        .and_then(|value| value.downcast::<CFNumber>())
        .and_then(|number| number.to_f64())
}

fn text(dictionary: &CFDictionary<CFString, CFType>, key: &str) -> Option<String> {
    dictionary
        .find(CFString::new(key))
        .and_then(|value| value.downcast::<CFString>())
        .map(|text| text.to_string())
}

fn boolean(dictionary: &CFDictionary<CFString, CFType>, key: &str) -> Option<bool> {
    use core_foundation::boolean::CFBoolean;
    dictionary
        .find(CFString::new(key))
        .and_then(|value| value.downcast::<CFBoolean>())
        .map(|flag| flag == CFBoolean::true_value())
}

#[link(name = "IOKit", kind = "framework")]
extern "C" {
    fn IOPSCopyPowerSourcesInfo() -> CFTypeRef;
    fn IOPSCopyPowerSourcesList(blob: CFTypeRef) -> CFArrayRef;
    fn IOPSGetPowerSourceDescription(blob: CFTypeRef, source: CFTypeRef) -> CFDictionaryRef;

    // Not public API. Confined to this process for exactly that reason.
    fn IOHIDEventSystemClientCreate(allocator: *const c_void) -> *const c_void;
    fn IOHIDEventSystemClientSetMatching(client: *const c_void, matching: CFDictionaryRef);
    fn IOHIDEventSystemClientCopyServices(client: *const c_void) -> CFArrayRef;
    fn IOHIDServiceClientCopyProperty(
        service: CFTypeRef,
        key: core_foundation::string::CFStringRef,
    ) -> CFTypeRef;
    fn IOHIDServiceClientCopyEvent(
        service: CFTypeRef,
        kind: i64,
        options: i32,
        timeout: i64,
    ) -> *const c_void;
    fn IOHIDEventGetFloatValue(event: *const c_void, field: i32) -> f64;
}

extern "C" {
    fn mach_host_self() -> u32;
    fn mach_task_self() -> u32;
    fn host_processor_info(
        host: u32,
        flavor: i32,
        count: *mut u32,
        info: *mut *mut u32,
        info_count: *mut u32,
    ) -> i32;
    fn host_statistics64(host: u32, flavor: i32, info: *mut u32, count: *mut u32) -> i32;
    fn vm_deallocate(task: u32, address: usize, size: usize) -> i32;
}
