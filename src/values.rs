//! What a key says when the number comes from somewhere else.
//!
//! A feed writes samples in; a key's `value` and `caption` read them out through
//! a template like `{vreme.temp|round}°`. Keeping those two apart means the
//! poller never learns about keys and the renderer never learns about HTTP, and
//! it leaves the whole substitution a pure function that a test can pin down.
//!
//! Formatting here is deliberately lossy. A key is 54 px wide once `MARGIN` is
//! taken off, which holds three comfortable glyphs, so `round` is the common
//! case and anything that would need six belongs in the caption instead.

use std::collections::BTreeMap;
use std::ffi::c_void;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// What a key shows when it has nothing true to say.
///
/// Never a zero and never the last value without a mark: a stale number that
/// looks current is the one failure worth designing against.
pub const NOTHING: &str = "—";

#[link(name = "CoreFoundation", kind = "framework")]
extern "C" {
    fn CFTimeZoneCopySystem() -> *const c_void;
    fn CFTimeZoneGetSecondsFromGMT(tz: *const c_void, at: f64) -> f64;
    fn CFAbsoluteTimeGetCurrent() -> f64;
    fn CFRelease(cf: *const c_void);
}

/// Seconds east of GMT, as this Mac understands it now.
///
/// Hosts are asked for `timezone=auto`, so their timestamps come back as local
/// civil time with no zone on them. Comparing one to the clock needs this
/// number and nothing else, no date library, and no parsing of zone names.
pub fn local_offset() -> i64 {
    unsafe {
        let zone = CFTimeZoneCopySystem();
        if zone.is_null() {
            return 0;
        }
        let seconds = CFTimeZoneGetSecondsFromGMT(zone, CFAbsoluteTimeGetCurrent());
        CFRelease(zone);
        seconds as i64
    }
}

/// One extracted field.
#[derive(Debug, Clone, PartialEq)]
pub enum Datum {
    Number(f64),
    Text(String),
}

impl Datum {
    pub fn as_number(&self) -> Option<f64> {
        match self {
            Datum::Number(value) => Some(*value),
            // A host that quotes its numbers is common enough to tolerate.
            Datum::Text(text) => text.trim().parse().ok(),
        }
    }

    pub fn as_text(&self) -> String {
        match self {
            Datum::Number(value) => plain(*value),
            Datum::Text(text) => text.clone(),
        }
    }
}

/// A run of values carrying its own time axis.
///
/// The axis is stored rather than inferred. An hourly series is not an hour
/// apart twice a year, so stepping by index puts the forecast an hour out on
/// exactly the two days somebody would notice.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Series {
    /// Civil seconds, as the host reported them.
    pub axis: Vec<i64>,
    pub values: Vec<f64>,
    /// The scalar field this series is the history and forecast of, so a key
    /// written `{vreme.temp}` can be scrubbed without naming the series.
    pub stands_for: Option<String>,
}

impl Series {
    /// The value in force at `civil`: the last point at or before it.
    ///
    /// Before the first point this is `None` rather than the first value,
    /// a series that does not reach back that far should say so.
    pub fn at(&self, civil: i64) -> Option<f64> {
        if self.axis.len() != self.values.len() || self.axis.is_empty() {
            return None;
        }
        // A point is in force for one step of the axis. Past the end the series
        // has simply run out, and the last value must not stand in for an hour
        // it never saw.
        if civil >= self.axis.last().copied().unwrap_or(0) + self.step() {
            return None;
        }
        let mut found = None;
        for (index, stamp) in self.axis.iter().enumerate() {
            if *stamp <= civil {
                found = Some(index);
            } else {
                break;
            }
        }
        found.map(|index| self.values[index])
    }

    /// The axis cadence, read off the first real gap rather than assumed.
    fn step(&self) -> i64 {
        self.axis
            .windows(2)
            .map(|pair| pair[1] - pair[0])
            .find(|gap| *gap > 0)
            .unwrap_or(3600)
    }
}

/// What one feed knew at one moment.
#[derive(Debug, Clone)]
pub struct Sample {
    pub at: SystemTime,
    pub fields: BTreeMap<String, Datum>,
    pub series: BTreeMap<String, Series>,
}

impl Sample {
    pub fn new(at: SystemTime) -> Sample {
        Sample {
            at,
            fields: BTreeMap::new(),
            series: BTreeMap::new(),
        }
    }
}

/// A finished string, and how much of it can be trusted.
#[derive(Debug, Clone, PartialEq)]
pub struct Resolved {
    pub text: String,
    /// False once any placeholder read a sample past its `stale_after`. The
    /// renderer desaturates rather than blanks: an old temperature is still
    /// information, an empty key is not.
    pub fresh: bool,
    /// True when a placeholder found no value at all.
    pub missing: bool,
}

impl Resolved {
    /// A literal string, which is what a key without placeholders resolves to.
    fn literal(text: String) -> Resolved {
        Resolved {
            text,
            fresh: true,
            missing: false,
        }
    }
}

struct Entry {
    sample: Option<Sample>,
    stale_after: Option<Duration>,
    /// Why the last poll failed, kept for the app to show rather than logged
    /// and forgotten.
    error: Option<String>,
}

/// Every feed's latest sample: the one place a key's text comes from.
pub struct Bindings {
    feeds: BTreeMap<String, Entry>,
    /// Bumped on every write, so a caller can skip work when nothing moved.
    rev: u64,
    offset: i64,
}

impl Default for Bindings {
    fn default() -> Bindings {
        Bindings::new()
    }
}

impl Bindings {
    pub fn new() -> Bindings {
        Bindings {
            feeds: BTreeMap::new(),
            rev: 0,
            offset: local_offset(),
        }
    }

    /// For tests, and for anywhere a fixed zone makes an assertion possible.
    pub fn with_offset(offset: i64) -> Bindings {
        Bindings {
            feeds: BTreeMap::new(),
            rev: 0,
            offset,
        }
    }

    pub fn rev(&self) -> u64 {
        self.rev
    }

    pub fn offset(&self) -> i64 {
        self.offset
    }

    /// Announces a feed and how long its data stays good, before any poll has
    /// run. A key bound to a feed that has never answered then renders an em
    /// dash instead of raising a lookup failure.
    pub fn declare(&mut self, name: &str, stale_after: Option<Duration>) {
        self.entry(name).stale_after = stale_after;
    }

    /// The feed's row, created empty if this is the first anyone has heard of
    /// it. It never touches `stale_after`: that belongs to whoever declared the
    /// feed, and a poll resetting it would mean nothing ever goes grey.
    fn entry(&mut self, name: &str) -> &mut Entry {
        self.feeds.entry(name.to_string()).or_insert(Entry {
            sample: None,
            stale_after: None,
            error: None,
        })
    }

    pub fn put(&mut self, name: &str, sample: Sample) {
        {
            let entry = self.entry(name);
            entry.sample = Some(sample);
            entry.error = None;
        }
        self.rev = self.rev.wrapping_add(1);
    }

    /// A failed poll keeps the last sample. The number on the key ages and
    /// desaturates on its own; throwing it away would replace information with
    /// nothing the moment a network blinks.
    pub fn fail(&mut self, name: &str, error: String) {
        self.entry(name).error = Some(error);
        self.rev = self.rev.wrapping_add(1);
    }

    pub fn error(&self, name: &str) -> Option<&str> {
        self.feeds.get(name)?.error.as_deref()
    }

    pub fn sample(&self, name: &str) -> Option<&Sample> {
        self.feeds.get(name)?.sample.as_ref()
    }

    pub fn names(&self) -> Vec<&str> {
        self.feeds.keys().map(String::as_str).collect()
    }

    /// How long ago this feed last answered.
    pub fn age(&self, name: &str, now: SystemTime) -> Option<Duration> {
        let sample = self.sample(name)?;
        Some(Duration::from_secs(elapsed(sample.at, now) as u64))
    }

    /// Whether this feed's last answer is past its own `stale_after`.
    ///
    /// Per feed, never per scene: two hosts fail separately, and a page that
    /// greys out entirely because one of them is down is lying about the other.
    pub fn is_stale(&self, name: &str, now: SystemTime) -> bool {
        let Some(entry) = self.feeds.get(name) else {
            return false;
        };
        let Some(sample) = entry.sample.as_ref() else {
            return false;
        };
        entry.stale(sample, now)
    }

    /// The longest run of values any feed carries.
    ///
    /// This is the real limit on walking a forecast: past the end of the
    /// series every reading is an em dash, so a knob that goes further is a
    /// knob with nothing at the end of it.
    pub fn span(&self) -> usize {
        self.feeds
            .values()
            .filter_map(|entry| entry.sample.as_ref())
            .flat_map(|sample| sample.series.values())
            .map(|series| series.values.len())
            .max()
            .unwrap_or(0)
    }

    /// Fills the holes in `template`.
    ///
    /// `hours` is the forecast scrub: 0 is now, and anything else reads every
    /// scrubbable field from its series instead of its current value.
    pub fn resolve(&self, template: &str, now: SystemTime, hours: i32) -> Resolved {
        if !template.contains('{') {
            return Resolved::literal(template.to_string());
        }

        let mut text = String::with_capacity(template.len());
        let mut fresh = true;
        let mut missing = false;
        let mut rest = template;

        while let Some(open) = rest.find('{') {
            push_literal(&mut text, &rest[..open]);
            rest = &rest[open + 1..];

            if let Some(stripped) = rest.strip_prefix('{') {
                text.push('{');
                rest = stripped;
                continue;
            }

            let Some(close) = rest.find('}') else {
                // An unclosed brace is a typo in a config, not a reason to show
                // nothing: leave it on the key so it can be found and fixed.
                text.push('{');
                text.push_str(rest);
                return Resolved {
                    text,
                    fresh,
                    missing,
                };
            };

            let (body, after) = rest.split_at(close);
            rest = &after[1..];

            match self.one(body, now, hours) {
                Some((value, stale)) => {
                    fresh &= !stale;
                    text.push_str(&value);
                }
                None => {
                    missing = true;
                    fresh = false;
                    text.push_str(NOTHING);
                }
            }
        }

        push_literal(&mut text, rest);
        Resolved {
            text,
            fresh,
            missing,
        }
    }

    /// One field as a number, for a ramp that colours by it.
    pub fn number(&self, path: &str, now: SystemTime, hours: i32) -> Option<f64> {
        let (name, field) = path.split_once('.')?;
        let sample = self.sample(name)?;
        self.pick(sample, field, now, hours)?.as_number()
    }

    /// How far behind the oldest feed a template reads is.
    ///
    /// This takes the caption's place once a reading goes stale: the number is
    /// still on the key, and how far behind it is, is now the useful fact.
    pub fn age_caption(&self, template: &str, now: SystemTime) -> String {
        let oldest = feeds_named(template)
            .into_iter()
            .filter_map(|name| self.age(name, now))
            .max();
        match oldest {
            Some(age) => ago(age.as_secs() as i64),
            None => NOTHING.to_string(),
        }
    }

    /// One placeholder, as `(text, stale)`.
    fn one(&self, body: &str, now: SystemTime, hours: i32) -> Option<(String, bool)> {
        let (path, spec) = match body.split_once('|') {
            Some((path, spec)) => (path.trim(), Some(spec.trim())),
            None => (body.trim(), None),
        };
        let (name, field) = match path.split_once('.') {
            Some((name, field)) => (name, Some(field)),
            None => (path, None),
        };

        let entry = self.feeds.get(name)?;
        let sample = entry.sample.as_ref()?;
        let stale = entry.stale(sample, now);

        let Some(field) = field else {
            // `{vreme|age}`: the feed itself, not one of its fields.
            return match spec {
                Some("age") => Some((ago(elapsed(sample.at, now)), stale)),
                _ => None,
            };
        };

        let datum = self.pick(sample, field, now, hours)?;
        let text = format(&datum, spec, self.civil(now))?;
        Some((text, stale))
    }

    /// The value a field has at the scrubbed hour.
    fn pick(&self, sample: &Sample, field: &str, now: SystemTime, hours: i32) -> Option<Datum> {
        if hours != 0 {
            if let Some(series) = sample
                .series
                .values()
                .find(|series| series.stands_for.as_deref() == Some(field))
            {
                let target = self.civil(now) + i64::from(hours) * 3600;
                // Past the end of the forecast the honest answer is an em dash.
                // Falling back to the present value would dress today's weather
                // up as the day after tomorrow's.
                return series.at(target).map(Datum::Number);
            }
        }
        sample.fields.get(field).cloned()
    }

    /// The wall clock as the hosts write it: local, with no zone attached.
    fn civil(&self, now: SystemTime) -> i64 {
        epoch(now) + self.offset
    }
}

impl Entry {
    fn stale(&self, sample: &Sample, now: SystemTime) -> bool {
        match self.stale_after {
            Some(limit) => elapsed(sample.at, now) > limit.as_secs() as i64,
            None => false,
        }
    }
}

/// Every feed a template reads, in the order they first appear.
///
/// Exposed so a config can be checked before anything is polled: a key reading
/// a feed nobody configured will only ever show an em dash, and that is worth
/// saying once at load rather than leaving on the dock.
pub fn feeds_named(template: &str) -> Vec<&str> {
    let mut names = Vec::new();
    let mut rest = template;

    while let Some(open) = rest.find('{') {
        rest = &rest[open + 1..];
        if let Some(stripped) = rest.strip_prefix('{') {
            rest = stripped;
            continue;
        }
        let Some(close) = rest.find('}') else {
            break;
        };
        let (body, after) = rest.split_at(close);
        rest = &after[1..];

        let path = body.split('|').next().unwrap_or(body).trim();
        let name = path.split('.').next().unwrap_or(path).trim();
        if !name.is_empty() && !names.contains(&name) {
            names.push(name);
        }
    }

    names
}

/// Copies literal text, collapsing the `{{` and `}}` escapes so a key can show
/// a brace of its own.
fn push_literal(text: &mut String, chunk: &str) {
    let mut rest = chunk;
    while let Some(brace) = rest.find("}}") {
        text.push_str(&rest[..brace]);
        text.push('}');
        rest = &rest[brace + 2..];
    }
    text.push_str(rest);
}

/// Applies one formatter.
///
/// `None` means this datum cannot be shown this way, a word asked to be
/// rounded, say, which the caller turns into an em dash rather than into a
/// plausible-looking zero.
fn format(datum: &Datum, spec: Option<&str>, now_civil: i64) -> Option<String> {
    let (name, arg) = match spec {
        Some(spec) => match spec.split_once(':') {
            Some((name, arg)) => (name, Some(arg)),
            None => (spec, None),
        },
        None => ("", None),
    };

    match name {
        "" => Some(datum.as_text()),
        "round" => datum.as_number().map(|value| fixed(value, 0)),
        "round1" => datum.as_number().map(|value| fixed(value, 1)),
        "frac2" => datum.as_number().map(|value| fixed(value, 2)),
        "int" => datum.as_number().map(|value| fixed(value.trunc(), 0)),
        "signed" => datum.as_number().map(|value| signed(value, 0)),
        "signed1" => datum.as_number().map(|value| signed(value, 1)),
        "k" => datum.as_number().map(thousands),
        "bytes" => datum.as_number().map(bytes),
        "dur" => datum.as_number().map(|value| hm(value as i64)),
        "age" => datum.as_number().map(|value| ago(value as i64)),
        "compass16" => datum.as_number().map(compass16),
        "wmo" => datum.as_number().map(|value| wmo(value as i64).to_string()),
        "clip" => {
            let width: usize = arg?.trim().parse().ok()?;
            Some(clip(&datum.as_text(), width))
        }
        "clock" => clock(&datum.as_text()),
        "until" => {
            let remaining = civil_from_iso(&datum.as_text())? - now_civil;
            (remaining > 0).then(|| hm(remaining))
        }
        // An unknown formatter is a typo, and a typo must not quietly pass the
        // raw value through as though it had been formatted.
        _ => None,
    }
}

/// A number the way somebody would write it by hand.
fn plain(value: f64) -> String {
    if value.fract() == 0.0 {
        fixed(value, 0)
    } else {
        fixed(value, 1)
    }
}

/// Rounds to `places`, and never renders a bare minus sign.
///
/// `-0.4` at zero places is `-0`, which on a 60 px key reads as a glyph that
/// has gone wrong rather than as a temperature.
fn fixed(value: f64, places: usize) -> String {
    let text = format!("{value:.places$}");
    let unsigned = text.trim_start_matches('-');
    if unsigned.chars().all(|c| c == '0' || c == '.') {
        unsigned.to_string()
    } else {
        text
    }
}

/// Rounds, and keeps the sign that makes a change a change.
fn signed(value: f64, places: usize) -> String {
    let text = fixed(value, places);
    if text.starts_with('-') || text.chars().all(|c| c == '0' || c == '.') {
        text
    } else {
        format!("+{text}")
    }
}

fn trim_tenth(text: String) -> String {
    match text.strip_suffix(".0") {
        Some(whole) => whole.to_string(),
        None => text,
    }
}

/// Counts, shortened: `1200` is `1.2k`.
fn thousands(value: f64) -> String {
    let magnitude = value.abs();
    if magnitude < 1_000.0 {
        fixed(value, 0)
    } else if magnitude < 1_000_000.0 {
        format!("{}k", trim_tenth(fixed(value / 1_000.0, 1)))
    } else if magnitude < 1_000_000_000.0 {
        format!("{}M", trim_tenth(fixed(value / 1_000_000.0, 1)))
    } else {
        format!("{}G", trim_tenth(fixed(value / 1_000_000_000.0, 1)))
    }
}

/// Bytes, shortened on the 1024 scale a Mac reports them on.
fn bytes(value: f64) -> String {
    const STEP: f64 = 1024.0;
    let magnitude = value.abs();
    if magnitude < STEP {
        return fixed(value, 0);
    }
    for (power, suffix) in [(1, "K"), (2, "M"), (3, "G"), (4, "T")] {
        let scale = STEP.powi(power);
        if magnitude < scale * STEP || suffix == "T" {
            let scaled = value / scale;
            let places = usize::from(scaled.abs() < 10.0);
            return format!("{}{suffix}", trim_tenth(fixed(scaled, places)));
        }
    }
    fixed(value, 0)
}

/// A span, at most five glyphs: `17d`, `2h14`, `47m`, `20s`.
///
/// Past a day it drops to whole days. An uptime of seventeen days reads as
/// `408h53` otherwise, which is arithmetic rather than an answer.
fn hm(seconds: i64) -> String {
    let seconds = seconds.max(0);
    if seconds >= 86_400 {
        format!("{}d", seconds / 86_400)
    } else if seconds >= 3600 {
        format!("{}h{:02}", seconds / 3600, (seconds % 3600) / 60)
    } else if seconds >= 60 {
        format!("{}m", seconds / 60)
    } else {
        format!("{seconds}s")
    }
}

/// How long ago, at most three glyphs, because this goes in a caption.
fn ago(seconds: i64) -> String {
    let seconds = seconds.max(0);
    if seconds >= 86_400 {
        format!("{}d", seconds / 86_400)
    } else if seconds >= 3600 {
        format!("{}h", seconds / 3600)
    } else if seconds >= 60 {
        format!("{}m", seconds / 60)
    } else {
        format!("{seconds}s")
    }
}

fn clip(text: &str, width: usize) -> String {
    if text.chars().count() <= width {
        return text.to_string();
    }
    text.chars().take(width).collect()
}

/// The `HH:MM` out of a host's timestamp.
///
/// Read off the string rather than converted, because `timezone=auto` already
/// made it local. Converting it twice is how a sunset lands an hour out.
fn clock(text: &str) -> Option<String> {
    let (_, time) = text.split_once('T')?;
    let clock: String = time.chars().take(5).collect();
    let mut glyphs = clock.chars();
    let shape = [true, true, false, true, true];
    for digit in shape {
        let c = glyphs.next()?;
        if digit != c.is_ascii_digit() {
            return None;
        }
    }
    Some(clock)
}

/// A bearing snapped to one of sixteen points, in degrees.
///
/// Quantised so the renderer's rotated-icon cache holds sixteen entries for
/// the life of the process instead of one per degree of wind.
fn compass16(degrees: f64) -> String {
    let step = 360.0 / 16.0;
    let point = (degrees.rem_euclid(360.0) / step).round() as i64 % 16;
    format!("{:.1}", point as f64 * step)
}

/// The WMO present-weather code as an icon in the bundled set.
///
/// All twenty-eight codes the hosts actually send, because the fallback drawing
/// a cheerful sun during freezing drizzle is the failure worth spelling out.
/// Night variants (`cloud-moon`) wait on `is_day`, which the page maps but this
/// table deliberately does not see: one input, one output.
pub fn wmo(code: i64) -> &'static str {
    match code {
        0 => "sun",
        // Mainly clear and partly cloudy are one glyph at 60 px. Pretending to
        // tell them apart would be detail the key cannot carry.
        1 | 2 => "cloud-sun",
        3 => "cloudy",
        45 | 48 => "cloud-fog",
        51 | 53 | 55 => "cloud-drizzle",
        // Anything freezing is ice on the road, which is the thing worth
        // reading off a desk at a glance.
        56 | 57 | 66 | 67 => "cloud-hail",
        61 | 63 => "cloud-rain",
        65 => "cloud-rain-wind",
        71 | 73 | 75 => "cloud-snow",
        77 => "snowflake",
        80 | 81 => "cloud-rain",
        82 => "cloud-rain-wind",
        85 | 86 => "cloud-snow",
        95 | 96 | 99 => "cloud-lightning",
        _ => "cloud-off",
    }
}

/// Every code `wmo` names on purpose, for the test that keeps the icon set and
/// this table from drifting apart.
pub const WMO_CODES: &[i64] = &[
    0, 1, 2, 3, 45, 48, 51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 71, 73, 75, 77, 80, 81, 82, 85, 86,
    95, 96, 99,
];

/// The wall clock as the hosts write it: local, with no zone attached.
///
/// Exposed so extraction can tell a timestamp that has passed from one still
/// to come, which is the difference between "sunset in 2h" and an em dash.
pub fn civil_now(at: SystemTime) -> i64 {
    epoch(at) + local_offset()
}

fn epoch(at: SystemTime) -> i64 {
    at.duration_since(UNIX_EPOCH)
        .map(|since| since.as_secs() as i64)
        .unwrap_or(0)
}

fn elapsed(then: SystemTime, now: SystemTime) -> i64 {
    (epoch(now) - epoch(then)).max(0)
}

/// Parses `2026-10-23T07:12`, with an optional seconds field or trailing `Z`,
/// into civil seconds: the instant it names, counted as though it were UTC.
pub fn civil_from_iso(text: &str) -> Option<i64> {
    let text = text.trim().trim_end_matches('Z');
    let (date, time) = text.split_once('T').or_else(|| text.split_once(' '))?;

    let mut parts = date.split('-');
    let year: i64 = parts.next()?.parse().ok()?;
    let month: i64 = parts.next()?.parse().ok()?;
    let day: i64 = parts.next()?.parse().ok()?;
    if !(1..=12).contains(&month) || !(1..=31).contains(&day) {
        return None;
    }

    let mut parts = time.split(':');
    let hour: i64 = parts.next()?.parse().ok()?;
    let minute: i64 = parts.next()?.parse().ok()?;
    let second: i64 = match parts.next() {
        Some(value) => value.split('.').next()?.parse().ok()?,
        None => 0,
    };
    if hour > 23 || minute > 59 || second > 60 {
        return None;
    }

    Some(days_from_civil(year, month, day) * 86_400 + hour * 3600 + minute * 60 + second)
}

/// Days since 1970-01-01 in the proleptic Gregorian calendar.
///
/// Hinnant's algorithm, which is branch-free past the February shift and needs
/// no table of leap years.
fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let year = if month <= 2 { year - 1 } else { year };
    let era = if year >= 0 { year } else { year - 399 } / 400;
    let year_of_era = year - era * 400;
    let shifted = (month + 9) % 12;
    let day_of_year = (153 * shifted + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    era * 146_097 + day_of_era - 719_468
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(civil: &str) -> SystemTime {
        // The tests run in a fixed zone, so a civil string is an instant.
        UNIX_EPOCH + Duration::from_secs(civil_from_iso(civil).unwrap() as u64)
    }

    fn weather(now: SystemTime) -> Bindings {
        let mut bindings = Bindings::with_offset(0);
        let mut sample = Sample::new(now);
        sample
            .fields
            .insert("temp".into(), Datum::Number(12.1));
        sample
            .fields
            .insert("code".into(), Datum::Number(3.0));
        sample
            .fields
            .insert("bearing".into(), Datum::Number(247.0));
        sample.fields.insert(
            "sunset".into(),
            Datum::Text("2026-10-23T18:04".into()),
        );
        sample.series.insert(
            "temp_h".into(),
            Series {
                axis: vec![
                    civil_from_iso("2026-10-23T12:00").unwrap(),
                    civil_from_iso("2026-10-23T13:00").unwrap(),
                    civil_from_iso("2026-10-23T14:00").unwrap(),
                ],
                values: vec![12.0, 14.0, 17.0],
                stands_for: Some("temp".into()),
            },
        );
        bindings.declare("vreme", Some(Duration::from_secs(7200)));
        bindings.put("vreme", sample);
        bindings
    }

    #[test]
    fn a_template_is_literal_text_with_holes_in_it() {
        let now = at("2026-10-23T12:30");
        let bindings = weather(now);
        assert_eq!(
            bindings.resolve("{vreme.temp|round}°", now, 0).text,
            "12°"
        );
        assert_eq!(
            bindings
                .resolve("oseća {vreme.temp|round1}°", now, 0)
                .text,
            "oseća 12.1°"
        );
        assert_eq!(bindings.resolve("bez rupa", now, 0).text, "bez rupa");
        assert_eq!(bindings.resolve("{{vreme}}", now, 0).text, "{vreme}");
    }

    #[test]
    fn a_missing_field_shows_an_em_dash_and_says_so() {
        let now = at("2026-10-23T12:30");
        let bindings = weather(now);

        let gone = bindings.resolve("{vreme.humidity|round}", now, 0);
        assert_eq!(gone.text, NOTHING);
        assert!(gone.missing);
        assert!(!gone.fresh);

        // A feed nobody has heard from, and a word asked to be rounded.
        assert_eq!(bindings.resolve("{vazduh.aqi|round}", now, 0).text, NOTHING);
        assert_eq!(bindings.resolve("{vreme.sunset|round}", now, 0).text, NOTHING);
        // An unknown formatter must not pass the raw value off as formatted.
        assert_eq!(bindings.resolve("{vreme.temp|fahrenheit}", now, 0).text, NOTHING);
        // A brace left open stays visible instead of eating the rest.
        assert_eq!(bindings.resolve("{vreme.temp", now, 0).text, "{vreme.temp");
    }

    #[test]
    fn a_stale_feed_still_shows_its_last_number() {
        let polled = at("2026-10-23T12:00");
        let bindings = weather(polled);

        let fresh = bindings.resolve("{vreme.temp|round}", at("2026-10-23T13:00"), 0);
        assert_eq!(fresh.text, "12");
        assert!(fresh.fresh);

        let old = bindings.resolve("{vreme.temp|round}", at("2026-10-23T15:00"), 0);
        assert_eq!(old.text, "12", "the number stays: it is still information");
        assert!(!old.fresh, "but it must be marked, or it reads as current");
        assert!(!old.missing);

        assert_eq!(
            bindings.resolve("{vreme|age}", at("2026-10-23T12:18"), 0).text,
            "18m"
        );
    }

    #[test]
    fn an_hourly_series_is_read_through_its_own_axis() {
        let now = at("2026-10-23T12:30");
        let bindings = weather(now);

        // Now is the current value, not the series.
        assert_eq!(bindings.resolve("{vreme.temp|round}", now, 0).text, "12");
        // Scrubbed, the same placeholder reads the forecast at that hour.
        assert_eq!(bindings.resolve("{vreme.temp|round}", now, 1).text, "14");
        assert_eq!(bindings.resolve("{vreme.temp|round}", now, 2).text, "17");
        // Past the end of the forecast: an em dash, never today dressed up as
        // the day after tomorrow.
        assert_eq!(bindings.resolve("{vreme.temp|round}", now, 9).text, NOTHING);
    }

    #[test]
    fn numbers_are_cut_to_the_width_of_a_key() {
        let now = at("2026-10-23T12:30");
        let bindings = weather(now);

        assert_eq!(bindings.resolve("{vreme.temp|int}", now, 0).text, "12");
        assert_eq!(bindings.resolve("{vreme.temp|frac2}", now, 0).text, "12.10");
        assert_eq!(bindings.resolve("{vreme.temp|signed}", now, 0).text, "+12");
        assert_eq!(bindings.resolve("{vreme.sunset|clock}", now, 0).text, "18:04");
        assert_eq!(bindings.resolve("{vreme.sunset|until}", now, 0).text, "5h34");

        assert_eq!(thousands(1_200.0), "1.2k");
        assert_eq!(thousands(1_000.0), "1k");
        assert_eq!(thousands(950.0), "950");
        assert_eq!(thousands(1_260_000.0), "1.3M");
        assert_eq!(bytes(1_536.0), "1.5K");
        assert_eq!(bytes(16.0 * 1024.0 * 1024.0 * 1024.0), "16G");
        assert_eq!(hm(8_040), "2h14");
        assert_eq!(hm(2_820), "47m");
        assert_eq!(hm(1_471_994), "17d", "an uptime, not 408h53");
        assert_eq!(hm(86_399), "23h59", "and not a day until it is one");
        assert_eq!(ago(172_800), "2d");
        assert_eq!(clip("Preuzimanje", 4), "Preu");

        // A rounded minus zero is a broken glyph, not a temperature.
        assert_eq!(fixed(-0.4, 0), "0");
        assert_eq!(signed(0.0, 0), "0");
        assert_eq!(signed(-2.5, 1), "-2.5");
    }

    #[test]
    fn a_bearing_snaps_to_sixteen_points() {
        assert_eq!(compass16(0.0), "0.0");
        assert_eq!(compass16(247.0), "247.5");
        assert_eq!(compass16(359.0), "0.0");
        assert_eq!(compass16(-10.0), "0.0");

        let mut points = std::collections::BTreeSet::new();
        for degrees in 0..360 {
            points.insert(compass16(degrees as f64));
        }
        assert_eq!(points.len(), 16, "the rotated-icon cache must stay small");
    }

    #[test]
    fn every_wmo_code_names_an_icon_that_exists() {
        for code in WMO_CODES {
            let name = wmo(*code);
            assert!(
                crate::icons::get(name).is_some(),
                "code {code} names {name}, which is not in the bundled set"
            );
        }
        assert!(crate::icons::get(wmo(1234)).is_some(), "the fallback too");
        assert_eq!(WMO_CODES.len(), 28);
        // Freezing drizzle must not come out as a cheerful sun.
        assert_ne!(wmo(56), wmo(0));
    }

    #[test]
    fn civil_time_survives_the_calendar() {
        assert_eq!(civil_from_iso("1970-01-01T00:00"), Some(0));
        assert_eq!(civil_from_iso("2026-10-23T07:12"), Some(1_792_739_520));
        assert_eq!(civil_from_iso("2026-10-23T07:12:30"), Some(1_792_739_550));
        // A leap day the hosts do send, and which index arithmetic gets wrong.
        assert_eq!(civil_from_iso("2024-02-29T12:00"), Some(1_709_208_000));
        assert_eq!(civil_from_iso("2026-10-23 07:12"), Some(1_792_739_520));
        assert_eq!(civil_from_iso("2026-10-23T07:12Z"), Some(1_792_739_520));

        assert_eq!(civil_from_iso("danas"), None);
        assert_eq!(civil_from_iso("2026-13-01T00:00"), None);
        assert_eq!(civil_from_iso("2026-10-23T25:00"), None);
    }
}
