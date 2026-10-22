//! Numbers from somewhere else, fetched on a thread of their own.
//!
//! One thread per feed, `curl` for the fetch and `serde_json` for the parse: a
//! fifteen-minute poll does not need an async runtime, and the daemon's single
//! loop must never block on a network it cannot see. The loop reads whatever
//! the pollers last wrote and carries on at its own 40 ms.
//!
//! Extraction is a JSON Pointer, optionally wrapped in a reducer over a slice.
//! `max:/hourly/precipitation_probability[0:6]` is "the worst it gets in the
//! next six hours", which is the shape every page here has needed so far.

use std::collections::BTreeMap;
use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::thread;
use std::time::{Duration, SystemTime};

use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::idle::parse_duration;
use crate::values::{civil_from_iso, Bindings, Datum, Sample, Series};

/// How long to give a host before giving up on this round.
const TIMEOUT: &str = "8";

/// Where a feed's JSON comes from.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FeedKind {
    /// A URL, fetched with curl.
    #[default]
    Http,
    /// A command, whose standard output is JSON.
    Shell,
}

/// One source of numbers.
#[derive(Debug, Default, Clone, Serialize, Deserialize)]
pub struct Feed {
    #[serde(default)]
    pub kind: FeedKind,
    /// The URL to fetch. `{lat}` and `{lon}` are filled in from the places the
    /// app supplies, so a home address need not sit in the config file.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    /// The command to run, when `kind = "shell"`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub run: Option<String>,
    /// How often, written the way every other duration here is written.
    #[serde(default = "default_every")]
    pub every: String,
    /// How long a sample stays trustworthy. Absent means forever, which is
    /// honest for a feed that reads this machine and wrong for anything else.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stale_after: Option<String>,
    /// Pointers that must arrive carrying a value.
    ///
    /// A 200 that quietly omits a field is a failure, not data. Without this a
    /// host that drops one key leaves that key's last number on the dock
    /// looking current for as long as the daemon runs.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub require: Vec<String>,
    /// Field name to where its value lives in the response.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub map: BTreeMap<String, Mapping>,
}

/// Where one field comes from.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(untagged)]
pub enum Mapping {
    /// A JSON Pointer, or a reducer over a slice of one.
    One(String),
    /// A run of values carrying its own time axis.
    Many(SeriesMap),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SeriesMap {
    /// Pointer to the array of values.
    pub series: String,
    /// Pointer to the array of timestamps they belong to.
    pub axis: String,
    /// The scalar field this series is the forecast of, so a key written
    /// `{vreme.temp}` can be scrubbed without ever naming the series.
    #[serde(default, rename = "for", skip_serializing_if = "Option::is_none")]
    pub stands_for: Option<String>,
}

fn default_every() -> String {
    "15m".to_string()
}

impl Feed {
    /// The poll interval, falling back to fifteen minutes rather than to zero:
    /// a typo in `every` must not turn into a hot loop against someone's host.
    pub fn every(&self) -> Duration {
        parse_duration(&self.every)
            .filter(|every| *every >= Duration::from_secs(1))
            .unwrap_or(Duration::from_secs(900))
    }

    pub fn stale_after(&self) -> Option<Duration> {
        parse_duration(self.stale_after.as_deref()?)
    }

    /// What to fetch or run, with the places filled in.
    pub fn target(&self, places: &BTreeMap<String, String>) -> Result<String> {
        let template = match self.kind {
            FeedKind::Http => self.url.as_deref().context("an http feed needs a url")?,
            FeedKind::Shell => self.run.as_deref().context("a shell feed needs a run")?,
        };
        fill(template, places)
    }
}

/// Substitutes `{name}` from `places`, and refuses to fetch a URL still
/// carrying a hole: a literal `{lat}` sent to a host is a puzzling 400, while
/// this says which value is missing.
pub fn fill(template: &str, places: &BTreeMap<String, String>) -> Result<String> {
    let mut text = template.to_string();
    for (name, value) in places {
        text = text.replace(&format!("{{{name}}}"), value);
    }
    if let Some(open) = text.find('{') {
        let end = text[open..]
            .find('}')
            .map(|offset| open + offset + 1)
            .unwrap_or(text.len());
        bail!("nothing to put in {}", &text[open..end]);
    }
    Ok(text)
}

/// Whether a mapping spec is one this runtime can follow.
///
/// A typo in a reducer would otherwise be silent: the field never arrives, the
/// key shows an em dash for the life of the daemon, and nothing says why.
pub fn understands(spec: &str) -> bool {
    spec.starts_with('/') || reducer(spec).is_some()
}

impl Feed {
    /// Everything about this feed that can be wrong before it is ever polled.
    pub fn check(&self) -> Result<()> {
        match self.kind {
            FeedKind::Http => {
                let url = self.url.as_deref().context("an http feed needs a url")?;
                if !url.starts_with("http://") && !url.starts_with("https://") {
                    bail!("the url must begin with http:// or https://, not {url:?}");
                }
            }
            FeedKind::Shell => {
                self.run.as_deref().context("a shell feed needs a run")?;
            }
        }

        match parse_duration(&self.every) {
            None => bail!("every {:?} is not a duration like 15m", self.every),
            // Not a style note: a sub-second poll against someone else's host
            // is a denial of service with this daemon's name on it.
            Some(every) if every < Duration::from_secs(1) => {
                bail!("every {:?} is too often; a second is the floor", self.every)
            }
            Some(_) => {}
        }
        if let Some(stale) = &self.stale_after {
            if parse_duration(stale).is_none() {
                bail!("stale_after {stale:?} is not a duration like 2h");
            }
        }

        for pointer in &self.require {
            if !pointer.starts_with('/') {
                bail!("require {pointer:?} must be a JSON pointer, so it starts with /");
            }
        }

        for (field, mapping) in &self.map {
            match mapping {
                Mapping::One(spec) => {
                    if !understands(spec) {
                        bail!(
                            "{field} reads {spec:?}, which is neither a JSON pointer nor \
                             one of {} over one",
                            OPERATIONS.join(", ")
                        );
                    }
                }
                Mapping::Many(map) => {
                    for (what, pointer) in [("series", &map.series), ("axis", &map.axis)] {
                        if !pointer.starts_with('/') {
                            bail!("{field}'s {what} {pointer:?} is not a JSON pointer");
                        }
                    }
                }
            }
        }

        Ok(())
    }
}

/// Where the dock is, read from a file beside the control socket.
///
/// Deliberately not in the config. The app round-trips that file, copies it to
/// `.bak` on every save and people paste it into bug reports; a latitude and a
/// longitude are a home address, so they live in a file nothing else touches.
pub fn places() -> BTreeMap<String, String> {
    let mut places = BTreeMap::new();

    let Some(path) = crate::control::socket_path()
        .ok()
        .and_then(|socket| socket.parent().map(|dir| dir.join("place.toml")))
    else {
        return places;
    };
    let Ok(text) = std::fs::read_to_string(&path) else {
        return places;
    };
    let table: toml::Table = match text.parse() {
        Ok(table) => table,
        Err(e) => {
            eprintln!("Place   : {} will not parse: {e}", path.display());
            return places;
        }
    };

    for (name, value) in table {
        // Numbers as well as strings: nobody writing `lat = 45.2671` by hand
        // should have to know it must be quoted.
        let text = match value {
            toml::Value::String(text) => text,
            other => other.to_string(),
        };
        places.insert(name, text);
    }
    places
}

/// Fetches and extracts once.
pub fn poll(feed: &Feed, target: &str, now: SystemTime) -> Result<Sample> {
    let body = fetch(feed, target)?;
    read(feed, &body, now)
}

fn fetch(feed: &Feed, target: &str) -> Result<String> {
    let output = match feed.kind {
        // `--url` rather than a bare argument, so a URL that begins with a dash
        // cannot be read as a flag. `--fail-with-body` makes a 404 a failure
        // while keeping the body, which is usually where the host explains.
        FeedKind::Http => Command::new("/usr/bin/curl")
            .args([
                "-sS",
                "--fail-with-body",
                "--compressed",
                "--max-time",
                TIMEOUT,
                "--url",
                target,
            ])
            .output()
            .context("running curl")?,
        FeedKind::Shell => Command::new("/bin/sh")
            .arg("-c")
            .arg(target)
            .output()
            .context("running the feed command")?,
    };

    if !output.status.success() {
        let complaint = String::from_utf8_lossy(&output.stderr);
        let complaint = complaint.trim();
        let body = String::from_utf8_lossy(&output.stdout);
        let detail = if complaint.is_empty() {
            body.trim().chars().take(200).collect::<String>()
        } else {
            complaint.chars().take(200).collect::<String>()
        };
        bail!("the fetch failed: {detail}");
    }

    String::from_utf8(output.stdout).context("the response is not text")
}

/// Turns a response body into a sample.
///
/// A mapped field that is simply absent is left out, and the key bound to it
/// shows an em dash. `require` is what makes an absence fatal — that choice
/// belongs to whoever wrote the feed, not to this function.
pub fn read(feed: &Feed, body: &str, now: SystemTime) -> Result<Sample> {
    let root: Value = serde_json::from_str(body).context("the response is not JSON")?;

    for pointer in &feed.require {
        match root.pointer(pointer) {
            Some(Value::Null) | None => bail!("the response carries no {pointer}"),
            Some(_) => {}
        }
    }

    let mut sample = Sample::new(now);
    for (field, mapping) in &feed.map {
        match mapping {
            Mapping::One(spec) => {
                if let Some(datum) = extract(&root, spec) {
                    sample.fields.insert(field.clone(), datum);
                }
            }
            Mapping::Many(map) => {
                if let Some(series) = series_from(&root, map) {
                    sample.series.insert(field.clone(), series);
                }
            }
        }
    }
    Ok(sample)
}

/// One field, by pointer or by reducer.
pub fn extract(root: &Value, spec: &str) -> Option<Datum> {
    match reducer(spec) {
        Some((operation, path, slice)) => {
            let values = numbers(root.pointer(&path)?);
            let values = slice.cut(&values);
            reduce(operation, values).map(Datum::Number)
        }
        None => datum(root.pointer(spec)?),
    }
}

const OPERATIONS: &[&str] = &["max", "min", "sum", "avg", "first", "last", "count"];

/// Splits `max:/hourly/x[0:6]` into its operation, pointer and bounds.
fn reducer(spec: &str) -> Option<(&str, String, Slice)> {
    let (operation, rest) = spec.split_once(':')?;
    if !rest.starts_with('/') || !OPERATIONS.contains(&operation) {
        return None;
    }
    match rest.split_once('[') {
        Some((path, bounds)) => Some((operation, path.to_string(), Slice::parse(bounds)?)),
        None => Some((operation, rest.to_string(), Slice::default())),
    }
}

/// Which part of an array a reducer runs over.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
struct Slice {
    start: usize,
    end: Option<usize>,
}

impl Slice {
    /// Parses `0:6]`, `2:]` or `3]`.
    fn parse(bounds: &str) -> Option<Slice> {
        let bounds = bounds.trim_end_matches(']');
        match bounds.split_once(':') {
            Some((start, end)) => Some(Slice {
                start: parse_bound(start)?.unwrap_or(0),
                end: parse_bound(end)?,
            }),
            None => {
                let only = parse_bound(bounds)?.unwrap_or(0);
                Some(Slice {
                    start: only,
                    end: Some(only + 1),
                })
            }
        }
    }

    fn cut<'a>(&self, values: &'a [f64]) -> &'a [f64] {
        let start = self.start.min(values.len());
        let end = self.end.unwrap_or(values.len()).clamp(start, values.len());
        &values[start..end]
    }
}

/// `Some(None)` for an empty bound, `None` for one that is not a number.
fn parse_bound(text: &str) -> Option<Option<usize>> {
    let text = text.trim();
    if text.is_empty() {
        return Some(None);
    }
    text.parse().ok().map(Some)
}

/// The numbers in an array, holes dropped.
///
/// A forecast with one null in it still has a usable maximum, and refusing the
/// whole array would blank six keys over one missing hour.
fn numbers(value: &Value) -> Vec<f64> {
    match value.as_array() {
        Some(array) => array.iter().filter_map(Value::as_f64).collect(),
        None => value.as_f64().into_iter().collect(),
    }
}

fn reduce(operation: &str, values: &[f64]) -> Option<f64> {
    if values.is_empty() {
        return None;
    }
    let total: f64 = values.iter().sum();
    match operation {
        "max" => values.iter().copied().reduce(f64::max),
        "min" => values.iter().copied().reduce(f64::min),
        "sum" => Some(total),
        "avg" => Some(total / values.len() as f64),
        "first" => values.first().copied(),
        "last" => values.last().copied(),
        "count" => Some(values.len() as f64),
        _ => None,
    }
}

fn datum(value: &Value) -> Option<Datum> {
    match value {
        Value::Number(number) => number.as_f64().map(Datum::Number),
        Value::String(text) => Some(Datum::Text(text.clone())),
        // A flag is a number on a key: `is_day` picks a glyph, not a sentence.
        Value::Bool(flag) => Some(Datum::Number(f64::from(u8::from(*flag)))),
        _ => None,
    }
}

fn series_from(root: &Value, map: &SeriesMap) -> Option<Series> {
    let values = root.pointer(&map.series)?.as_array()?;
    let axis = root.pointer(&map.axis)?.as_array()?;

    let mut series = Series {
        axis: Vec::with_capacity(values.len()),
        values: Vec::with_capacity(values.len()),
        stands_for: map.stands_for.clone(),
    };
    for (stamp, value) in axis.iter().zip(values) {
        // A hole drops the whole pair. Keeping one side would slide every later
        // value an hour out, which is the error this axis exists to prevent.
        let (Some(stamp), Some(value)) = (
            stamp.as_str().and_then(civil_from_iso),
            value.as_f64(),
        ) else {
            continue;
        };
        series.axis.push(stamp);
        series.values.push(value);
    }
    (!series.axis.is_empty()).then_some(series)
}

/// The pollers running for one config.
///
/// Dropping this stops them. Nothing is joined: a curl holding its eight-second
/// timeout must not hold a config reload up for eight seconds.
pub struct Feeds {
    stop: Arc<AtomicBool>,
}

impl Feeds {
    pub fn start(
        feeds: &BTreeMap<String, Feed>,
        places: &BTreeMap<String, String>,
        bindings: Arc<Mutex<Bindings>>,
    ) -> Feeds {
        let stop = Arc::new(AtomicBool::new(false));

        for (name, feed) in feeds {
            // Declared before the first poll, so a key bound to a feed that has
            // not answered yet shows an em dash instead of nothing at all.
            write(&bindings).declare(name, feed.stale_after());

            let target = match feed.target(places) {
                Ok(target) => target,
                Err(error) => {
                    // Said once, out loud: this is a config problem, and the
                    // commonest one is coordinates nobody has set yet. Leaving
                    // it only in the bindings means six em dashes and no clue.
                    eprintln!("Feeds   : {name} cannot run: {error:#}");
                    write(&bindings).fail(name, format!("{error:#}"));
                    continue;
                }
            };

            let owned = name.clone();
            let feed = feed.clone();
            let stop = Arc::clone(&stop);
            let shared = Arc::clone(&bindings);
            let thread = thread::Builder::new()
                .name(format!("feed-{name}"))
                .spawn(move || run(owned, feed, target, stop, shared));
            if let Err(error) = thread {
                write(&bindings).fail(name, format!("no thread for this feed: {error}"));
            }
        }

        Feeds { stop }
    }
}

impl Drop for Feeds {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
    }
}

fn run(
    name: String,
    feed: Feed,
    target: String,
    stop: Arc<AtomicBool>,
    bindings: Arc<Mutex<Bindings>>,
) {
    let every = feed.every();
    let mut failures: u32 = 0;

    while !stop.load(Ordering::Relaxed) {
        match poll(&feed, &target, SystemTime::now()) {
            Ok(sample) => {
                failures = 0;
                write(&bindings).put(&name, sample);
            }
            Err(error) => {
                failures = failures.saturating_add(1);
                write(&bindings).fail(&name, format!("{error:#}"));
            }
        }

        // A host that is down is not worth asking on schedule; a host that is
        // up must never be asked more often than it said.
        if !nap(&stop, every * failures.clamp(1, 4)) {
            return;
        }
    }
}

/// Sleeps in slices, so a config reload is noticed in a quarter of a second
/// instead of in fifteen minutes.
fn nap(stop: &AtomicBool, total: Duration) -> bool {
    const SLICE: Duration = Duration::from_millis(250);
    let mut left = total;
    while left > Duration::ZERO {
        if stop.load(Ordering::Relaxed) {
            return false;
        }
        let slice = left.min(SLICE);
        thread::sleep(slice);
        left -= slice;
    }
    !stop.load(Ordering::Relaxed)
}

/// A poller that panicked must not take the dock down with it: the lock is
/// taken back and the remaining feeds carry on.
fn write(bindings: &Arc<Mutex<Bindings>>) -> std::sync::MutexGuard<'_, Bindings> {
    bindings.lock().unwrap_or_else(PoisonError::into_inner)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::UNIX_EPOCH;

    /// Shaped like what api.open-meteo.com actually returns, hole and all.
    const BODY: &str = r#"{
        "current": {
            "temperature_2m": 12.1,
            "weather_code": 3,
            "wind_speed_10m": 15.1,
            "is_day": 0
        },
        "hourly": {
            "time": ["2026-10-23T12:00", "2026-10-23T13:00", "2026-10-23T14:00"],
            "temperature_2m": [12.0, null, 17.0],
            "precipitation_probability": [39, 36, 31, 22, 11, 2, 88]
        },
        "daily": { "sunset": ["2026-10-23T18:04"] }
    }"#;

    fn weather() -> Feed {
        let mut feed = Feed {
            kind: FeedKind::Http,
            url: Some("https://example.invalid/?lat={lat}&lon={lon}".into()),
            every: "15m".into(),
            stale_after: Some("2h".into()),
            require: vec!["/current/temperature_2m".into()],
            ..Feed::default()
        };
        feed.map.insert(
            "temp".into(),
            Mapping::One("/current/temperature_2m".into()),
        );
        feed.map
            .insert("code".into(), Mapping::One("/current/weather_code".into()));
        feed.map
            .insert("day".into(), Mapping::One("/current/is_day".into()));
        feed.map
            .insert("sunset".into(), Mapping::One("/daily/sunset/0".into()));
        feed.map.insert(
            "rain6".into(),
            Mapping::One("max:/hourly/precipitation_probability[0:6]".into()),
        );
        feed.map.insert(
            "temp_h".into(),
            Mapping::Many(SeriesMap {
                series: "/hourly/temperature_2m".into(),
                axis: "/hourly/time".into(),
                stands_for: Some("temp".into()),
            }),
        );
        feed
    }

    #[test]
    fn a_pointer_and_a_reducer_read_the_same_response() {
        let sample = read(&weather(), BODY, UNIX_EPOCH).unwrap();

        assert_eq!(sample.fields["temp"], Datum::Number(12.1));
        assert_eq!(sample.fields["code"], Datum::Number(3.0));
        assert_eq!(
            sample.fields["sunset"],
            Datum::Text("2026-10-23T18:04".into())
        );
        // The worst of the next six hours, not of the whole array: the 88 in
        // the seventh slot is tomorrow's problem.
        assert_eq!(sample.fields["rain6"], Datum::Number(39.0));
        // A flag arrives as a number, because a key draws a glyph from it.
        assert_eq!(sample.fields["day"], Datum::Number(0.0));
    }

    #[test]
    fn a_reducer_takes_only_the_slice_it_names() {
        let root: Value = serde_json::from_str(BODY).unwrap();
        let path = "/hourly/precipitation_probability";
        for (spec, expected) in [
            ("max:/hourly/precipitation_probability", 88.0),
            ("min:/hourly/precipitation_probability[0:6]", 2.0),
            ("first:/hourly/precipitation_probability[2:]", 31.0),
            ("last:/hourly/precipitation_probability[0:3]", 31.0),
            ("count:/hourly/precipitation_probability", 7.0),
            ("sum:/hourly/precipitation_probability[0:2]", 75.0),
        ] {
            assert_eq!(
                extract(&root, spec),
                Some(Datum::Number(expected)),
                "{spec}"
            );
        }
        // An unknown operation is not a pointer either, so it reads as nothing
        // rather than as a plausible number.
        assert_eq!(extract(&root, &format!("median:{path}")), None);
    }

    #[test]
    fn a_hole_drops_the_pair_it_would_have_slid() {
        let sample = read(&weather(), BODY, UNIX_EPOCH).unwrap();
        let series = &sample.series["temp_h"];

        assert_eq!(series.values, vec![12.0, 17.0]);
        assert_eq!(
            series.axis,
            vec![
                civil_from_iso("2026-10-23T12:00").unwrap(),
                // 13:00 went with its missing value. 14:00 keeps its own hour
                // instead of sliding back into the gap.
                civil_from_iso("2026-10-23T14:00").unwrap(),
            ]
        );
        assert_eq!(series.stands_for.as_deref(), Some("temp"));
    }

    #[test]
    fn a_two_hundred_without_a_required_field_is_a_failure() {
        let feed = weather();
        let silent = r#"{"current":{"weather_code":3}}"#;
        let error = read(&feed, silent, UNIX_EPOCH).unwrap_err();
        assert!(
            error.to_string().contains("/current/temperature_2m"),
            "the error must name the field: {error}"
        );

        // Nothing required, and the same body is simply thin rather than wrong.
        let lenient = Feed {
            require: Vec::new(),
            ..feed
        };
        let sample = read(&lenient, silent, UNIX_EPOCH).unwrap();
        assert!(!sample.fields.contains_key("temp"));
        assert_eq!(sample.fields["code"], Datum::Number(3.0));
    }

    #[test]
    fn a_url_with_nothing_to_fill_it_says_which_value_is_missing() {
        let feed = weather();
        let mut places = BTreeMap::new();
        places.insert("lat".to_string(), "45.25".to_string());

        let error = feed.target(&places).unwrap_err();
        assert!(error.to_string().contains("{lon}"), "{error}");

        places.insert("lon".to_string(), "19.83".to_string());
        let target = feed.target(&places).unwrap();
        assert_eq!(target, "https://example.invalid/?lat=45.25&lon=19.83");
    }

    #[test]
    fn a_feed_reads_its_own_durations_and_refuses_a_hot_loop() {
        let feed = weather();
        assert_eq!(feed.every(), Duration::from_secs(900));
        assert_eq!(feed.stale_after(), Some(Duration::from_secs(7200)));

        let typo = Feed {
            every: "soon".into(),
            ..Feed::default()
        };
        assert_eq!(typo.every(), Duration::from_secs(900));
        let zero = Feed {
            every: "0".into(),
            ..Feed::default()
        };
        assert_eq!(zero.every(), Duration::from_secs(900));
    }

    /// Not run by default, because the suite has to pass on a train. Run it on
    /// purpose with `cargo test -- --ignored` whenever a host's shape is in
    /// doubt: it is the only check that the pointers in the shipped config
    /// still name fields these hosts actually send.
    #[test]
    #[ignore = "reaches two hosts over the network"]
    fn the_hosts_still_answer_the_way_the_shipped_feeds_expect() {
        let mut places = BTreeMap::new();
        places.insert("lat".to_string(), "45.2671".to_string());
        places.insert("lon".to_string(), "19.8335".to_string());

        let wanted: &[(&str, &[&str])] = &[
            (
                "https://api.open-meteo.com/v1/forecast?latitude={lat}&longitude={lon}\
                 &current=temperature_2m,apparent_temperature,relative_humidity_2m,\
                 weather_code,wind_speed_10m,wind_gusts_10m,wind_direction_10m,is_day\
                 &hourly=precipitation_probability,temperature_2m&forecast_hours=24\
                 &daily=temperature_2m_max,temperature_2m_min,sunrise,sunset&timezone=auto",
                &[
                    "/current/temperature_2m",
                    "/current/apparent_temperature",
                    "/current/relative_humidity_2m",
                    "/current/weather_code",
                    "/current/wind_speed_10m",
                    "/current/wind_gusts_10m",
                    "/current/wind_direction_10m",
                    "/daily/temperature_2m_max/0",
                    "/daily/temperature_2m_min/0",
                    "/daily/sunset/0",
                ],
            ),
            (
                "https://air-quality-api.open-meteo.com/v1/air-quality\
                 ?latitude={lat}&longitude={lon}&current=european_aqi,pm2_5,pm10,uv_index",
                &[
                    "/current/european_aqi",
                    "/current/pm2_5",
                    "/current/pm10",
                    "/current/uv_index",
                ],
            ),
        ];

        for (url, pointers) in wanted {
            let mut feed = Feed {
                url: Some(url.replace(['\n', ' '], "")),
                require: pointers.iter().map(|p| p.to_string()).collect(),
                ..Feed::default()
            };
            for pointer in *pointers {
                feed.map
                    .insert(pointer.to_string(), Mapping::One(pointer.to_string()));
            }
            // The hourly axis is the one thing a pointer check cannot prove.
            feed.map.insert(
                "run".to_string(),
                Mapping::Many(SeriesMap {
                    series: "/hourly/temperature_2m".to_string(),
                    axis: "/hourly/time".to_string(),
                    stands_for: Some("t".to_string()),
                }),
            );

            let target = feed.target(&places).expect("a filled url");
            let sample = poll(&feed, &target, SystemTime::now())
                .unwrap_or_else(|error| panic!("{target}: {error:#}"));

            for pointer in *pointers {
                assert!(
                    sample.fields.contains_key(*pointer),
                    "{target} no longer sends {pointer}"
                );
            }
            if target.contains("/forecast") {
                let run = sample.series.get("run").expect("an hourly series");
                assert!(run.axis.len() >= 12, "an hourly axis of {}", run.axis.len());
                assert!(run.at(run.axis[0]).is_some());
            }
        }
    }

    #[test]
    fn a_feed_survives_a_round_trip_through_toml() {
        let mut feeds = BTreeMap::new();
        feeds.insert("vreme".to_string(), weather());

        let text = toml::to_string(&feeds).unwrap();
        let again: BTreeMap<String, Feed> = toml::from_str(&text).unwrap();
        let back = &again["vreme"];

        assert_eq!(back.require, vec!["/current/temperature_2m".to_string()]);
        assert_eq!(back.map.len(), 6);
        match &back.map["rain6"] {
            Mapping::One(spec) => {
                assert_eq!(spec, "max:/hourly/precipitation_probability[0:6]")
            }
            Mapping::Many(_) => panic!("a pointer came back as a series"),
        }
        match &back.map["temp_h"] {
            Mapping::Many(map) => assert_eq!(map.stands_for.as_deref(), Some("temp")),
            Mapping::One(_) => panic!("a series came back as a pointer"),
        }
    }
}
